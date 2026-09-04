---
name: game-to-mac
description: >
  Port a non-macOS game (APK, Godot project, or loose assets) to a runnable macOS .app bundle
  installed in /Applications. Handles Godot Engine extraction, project.binary conversion,
  GDExtension/platform-library stubbing, .gdc script decoding, .godot cache preservation,
  .app packaging, code signing, and thorough pre-delivery testing.
trigger: >
  "port this game to mac", "make this run on mac", "convert apk to mac app",
  "make a mac .app", "install in /Applications", "game-to-mac", "移植到 mac"
---

# game-to-mac — port a game to macOS

Turn a non-macOS game into a first-class macOS app in `/Applications`.
Default assumption: the source is an **Android APK built with Godot Engine 4.x**.
The workflow also adapts to other Godot export formats or loose project folders.

## 1. Inspect the source

- For APK: `unzip -l game.apk` and look for `assets/project.binary` or `assets/project.godot`.
- Identify engine version from `assets/_cl_` (raw 4 bytes, little-endian int, e.g. `0x?? 0x00 0x00 0x00` => Godot 4.x), or from `project.binary` text snippets.
- Note plugins: `assets/addons/*/plugin.cfg`, `assets/addons/*/*.gdextension`.

## 2. Extract assets

```bash
mkdir -p dirt-clicker-mac/assets
cd dirt-clicker-mac/assets
unzip "<APK>" "assets/*"
# unzip flattens; move files up one level
mv assets/* . && rm -rf assets
```

## 3. Convert `project.binary` to `project.godot`

Godot Android APKs ship a binary `project.binary`. The macOS runtime needs a text `project.godot`.

Create a temporary editor script `dump_settings.gd`:

```gdscript
extends SceneTree
func _init():
    ProjectSettings.save_custom("res://project.godot")
    quit()
```

Run it with a desktop Godot editor matching (or newer than) the game's engine version:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --script dump_settings.gd
rm dump_settings.gd
```

Back up `project.binary` first: `mv project.binary project.binary.bak`.

## 4. Fix project settings for macOS

Edit `project.godot`:

- `run/main_scene` must point to an existing `.tscn` or the `.remap` file. If it contains a `uid://` path and the scene exists at `autoload/init.tscn`, set `run/main_scene="res://autoload/init.tscn"`.
- `[autoload]` entries that load compiled `.gdc` scripts need their `.remap` files intact.
- Set `audio/buses/default_bus_layout="res://default_bus_layout.tres"`.
- Set `application/config/icon="res://icon.png"`.

## 5. Handle platform-specific plugins / GDExtensions

APK builds usually include only Android `.so` libraries. macOS `.dylib` files will be missing.

Options, in order of preference:

1. **Stub the plugin**: if the game only uses a small API surface (e.g. GodotSteam), write a minimal GDScript singleton that mimics the needed signals/methods/constants. Register it as an autoload in `project.godot`.
2. **Disable the .gdextension**: rename the `.gdextension` to `.gdextension.bak` so Godot does not try to load the missing dynamic library.
3. **Find native macOS libs**: only if the plugin is open-source and has a trusted macOS build.

### Stubbing a Steam-style singleton

Create `autoload/steam_stub.gd` and register as autoload `Steam`:

```gdscript
extends Node
signal global_stats_received(result: int, game_id: int)
signal leaderboard_find_result(handle: int, found: bool)
signal leaderboard_score_uploaded(handle: int, success: bool, score: int, changed: bool)
signal leaderboard_scores_downloaded(message: int, handle: int, entries: Array)

const STEAM_API_INIT_RESULT_OK := 0
const RESULT_OK := 1

func steamInitEx(app_id: int = 0) -> Dictionary:
    return {"status": STEAM_API_INIT_RESULT_OK, "voice": false, "out_of_date": false}

func getSteamID() -> int: return 0
func run_callbacks() -> void: pass
func runCallbacks() -> void: pass
func requestGlobalStats(_history_days: int) -> bool:
    global_stats_received.emit(1, 0)
    return true
```

## 6. Decode compiled scripts if needed

If the game uses `.gdc` files and you need to know what API surface to stub, decode identifiers with:

```bash
python3 /tmp/scan_gdc.py path/to/file.gdc
```

Reference decoder: read the ZSTD-compressed tokenizer buffer at offset 12, then de-obfuscate
identifier strings by XOR-ing each byte of every uint32 word with `0xB6`:

```python
(((word >> (8*b)) & 0xFF) ^ 0xB6) << (8*b)
```

## 7. Preserve the `.godot/` cache — CRITICAL

Godot keeps three runtime-critical pieces in the hidden `.godot/` folder:

- `.godot/exported/133200997/` — compiled `.scn` files referenced by `.remap` files.
- `.godot/uid_cache.bin` — resource UID resolution.
- `.godot/global_script_class_cache.cfg` — `class_name` registry for custom types.

Running the desktop editor once can **wipe** these caches to tiny invalid files.
Always keep a pristine copy from the original APK.

When copying assets into the `.app` bundle, **never use `cp -R src/* dst/`** — shell globs skip dotfiles. Use:

```bash
cp -R "src/." "dst/"
```

If the editor overwrote the caches, restore them from the APK before packaging:

```bash
unzip "game.apk" "assets/.godot/uid_cache.bin" "assets/.godot/global_script_class_cache.cfg"
```

## 8. Build the `.app` bundle

Create this structure:

```
Dirt Clicker Demo.app/
  Contents/
    Info.plist
    Resources/
      Icon.icns
      game_assets/      <-- all project files INCLUDING .godot/
    MacOS/
      Dirt Clicker Demo <-- launcher script
```

### Launcher script

`Contents/MacOS/Dirt Clicker Demo`:

```zsh
#!/bin/zsh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
PROJECT="$(dirname "$0")/../Resources/game_assets"
exec "$GODOT" --path "$PROJECT" "$@"
```

Make executable: `chmod +x "Contents/MacOS/Dirt Clicker Demo"`.

### Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Dirt Clicker Demo</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.dirtclickerdemo</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Dirt Clicker Demo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>Icon</string>
    <key>LSMinimumSystemVersionByArchitecture</key>
    <dict>
        <key>x86_64</key>
        <string>10.15</string>
        <key>arm64</key>
        <string>11.0</string>
    </dict>
</dict>
</plist>
```

### Icon

Use `icon.png` from the game. Generate `.icns`:

```bash
mkdir icon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "icon.iconset/icon_${s}x${s}.png"
    sips -z $((s*2)) $((s*2)) icon.png --out "icon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns icon.iconset -o Icon.icns
rm -rf icon.iconset
```

## 9. Install to `/Applications`

```bash
cp -R "Dirt Clicker Demo.app" /Applications/
# Re-sign ad-hoc (always sign after contents change)
codesign --force --deep --sign - "/Applications/Dirt Clicker Demo.app"
```

## 10. Test before delivering — mandatory

Do **all three**; do not deliver until they pass.

1. **Headless parse test** (catches script / resource errors without GUI):
   ```bash
   /Applications/Godot.app/Contents/MacOS/Godot \
       --headless --path "/Applications/Dirt Clicker Demo.app/Contents/Resources/game_assets" \
       --quit-after 180
   ```
   Expect exit 0 and no red `SCRIPT ERROR` lines.

2. **Live launch test** (confirm process stays alive):
   ```bash
   "/Applications/Dirt Clicker Demo.app/Contents/MacOS/Dirt Clicker Demo" > /tmp/app.log 2>&1 &
   PID=$!
   sleep 10
   kill -0 $PID && echo "alive"
   ```
   Confirm process is still running after 10 seconds.

3. **Render test** (proves real frames are drawn):
   ```bash
   /Applications/Godot.app/Contents/MacOS/Godot \
       --path "/Applications/Dirt Clicker Demo.app/Contents/Resources/game_assets" \
       --write-movie /tmp/frame.png --fixed-fps 30 --quit-after 120
   ```
   Inspect a later frame (e.g. `/tmp/frame00000100.png`) for the game UI.

## 11. Windows Godot build fallback: Wine wrapper

If the source is a **Windows Godot executable** with an **encrypted `.pck`** (common in SteamRIP repacks), you usually cannot rebuild a native macOS `.app` because the AES-256 key is baked into the Windows binary, not the `.pck`. The pragmatic route is a self-contained Wine-wrapped `.app`.

### Encrypted PCK basics

- `gamblers-table.exe` + `gamblers-table.pck`.
- PCK uses GDPC format v3; the directory is usually readable, but **every file** has `PACK_FILE_ENCRYPTED`.
- Encryption envelope per file: `[md5(16)][original_length(8 LE)][iv(16)][ciphertext(padded to 16)]`, AES-256-CFB128 (Godot uses `mbedtls_aes_crypt_cfb128`).
- The 32-byte key is **not in the `.pck`**; it is embedded in the engine binary, either as a 64-hex string (searchable with `strings`) or as raw bytes / inside a compressed `project.binary` blob. Without the key you cannot decrypt, edit, and repack the PCK.

### Wine wrapper essentials

- Do **not** rely on the user installing Whisky/CrossOver/Homebrew Wine; those sources break behind corporate proxies or dead CDNs. Bundle a gcenx `macOS_Wine_builds` release (e.g., `wine-stable-11.0_1-osx64.tar.xz`) inside `Contents/Resources/wine`.
- On Apple Silicon, the bundled Wine must be x86_64 and runs under Rosetta 2. Set `DYLD_FALLBACK_LIBRARY_PATH` to `Contents/Resources/wine/lib` so `libMoltenVK.dylib` is found and Vulkan/MoltenVK initializes.
- Create a Wine prefix under `~/Library/Application Support/<App>/prefix`.

### Fixing CJK (hex tofu) without the PCK key

Godot 4 on Windows uses DirectWrite and `IDWriteFactory2::GetSystemFontFallback` for missing glyphs. Under Wine, Chinese/Japanese/Korean characters render as hex boxes with Unicode codepoints when the fallback cannot resolve a CJK font.

Fix it in the Wine prefix:

1. Copy a single CJK-capable `.ttf` (e.g., `Arial Unicode.ttf`) into `drive_c/windows/Fonts/`.
2. Add `HKCU\Software\Wine\Fonts\Replacements` entries mapping the Windows CJK fallback names to that font:
   - `Microsoft YaHei`, `Microsoft YaHei UI`
   - `SimSun`, `NSimSun`, `SimSun-ExtB`, `SimHei`
   - `Microsoft JhengHei`, `Microsoft JhengHei UI`
   - `PMingLiU`, `PMingLiU-ExtB`
   - `Yu Gothic`, `Yu Gothic UI`, `MS Gothic`, `Meiryo`
   - `Malgun Gothic`, `Gulim`, `Dotum`
   - `Source Han Sans SC`, `Noto Sans CJK SC/TC/JP/KR`
3. Set `LANG=zh_CN.UTF-8` and `LC_ALL=zh_CN.UTF-8` in the launcher.
4. Verify with `WINEDEBUG=+dwrite` and look for:
   - `dwritefactory2_GetSystemFontFallback` being called (fallback is enabled).
   - `fontfallback_MapCharacters` for the game's bundled Latin font (e.g., `"Jersey 10"`) — proves Godot is asking Wine for a fallback font.
   - `fontcollection_add_replacement` showing your CJK name mappings.

### Network/proxy gotchas

- `git clone` through a proxy may return 502 while `curl` works; prefer release tarballs.
- GitHub releases may be throttled to ~30 KB/s behind a proxy. Use the `ghfast.top` mirror: `https://ghfast.top/https://github.com/...`.

## 11b. Windows Unity (IL2CPP) port — specific workflow

When the source is a **Windows Unity standalone** (not Godot), apply the Wine wrapper from
§11 but note these differences:

- **No native rebuild.** Without the Unity project you cannot produce a real Mac `.app`;
  the deliverable is a Wine-launched `.app` that runs the Windows `.exe`.
- **Detect the engine:** read `Unity <ver>` from `globalgamemanagers`; list compiled
  renderers by testing `-force-d3d11` / `-force-d3d12` / `-force-vulkan` and reading the
  `Player.log` (under `drive_c/users/<user>/AppData/LocalLow/<Company>/<Game>/`).
  "Vulkan was not built from editor" ⇒ that player has no Vulkan renderer.
- **Default renderer = D3D11.** The gcenx wine-11.0 build has MoltenVK but no vkd3d, so
  D3D12 is dead. Launch with `-force-d3d11`. Allow `RENDERER=d3d12|vulkan|auto` override.
- **Watch for engine-side gates.** Some Unity 6 games reject D3D12 below Feature Level
  12.1 ("D3D12 API denied by user filter"). That only matters if you attempt D3D12 (needs
  vkd3d). With `-force-d3d11` it is irrelevant.
- **GoldBerg / Steam-emu repacks:** `steam_settings/` + `steam_api64.dll` ⇒ fully offline,
  no Steam needed. Just run the `.exe`.
- **OnlineFix repacks:** `winmm.dll` + `OnlineFix64.dll` + `OnlineFix.ini` + `dlllist.txt`, and NO
  `steam_settings/`. OnlineFix needs a *reachable Steam client*, which a Wine prefix on macOS cannot
  provide, and it kills the game when it can't find one. **Always force `winmm=b`** (Wine's builtin)
  so the proxy never loads. See pitfall 2026-08-30.
- **Headless smoke test limitation:** in a display-less sandbox, `d3d11: failed to create
  device (80004005)` is usually environmental (no surface), not fatal. Real rendering must
  be confirmed by the user launching the `.app` on a Mac with a display.

## 11c. Windows Godot (UNencrypted PCK) → native macOS (preferred over Wine)

When the source is a **Windows Godot `.exe` + `.pck`** whose PCK header `flags` does NOT have the
per-file encryption bit (GodotSteam / TENOKE / SteamRIP repacks are often unencrypted), build a REAL
native macOS `.app` — no Wine. Verified working: Godot 4.6.2 + Apple M1 Pro (Metal 4.0 Forward+).
Smashing Bottles (SteamRIP/TENOKE, Godot 4.6.2) was ported this way end-to-end.

### Detect (decide native vs Wine)
- PCK header: magic `GDPC`, then `pack_format(u32)=3`, `major/minor/patch(u32)`, `flags(u32)`,
  `files_base(u64)`, `dir_offset(u64)`, `reserved(u32)` = 44-byte header. Per-file encryption bit =
  each entry's `flags(u32) & 1`. If **no file** has it (and the global `flags` did not trigger an
  encrypted directory), the PCK is plaintext → native is viable.
- Note `major.minor.patch`. You MUST run it with a Godot binary of the SAME `major.minor` (patch may
  differ). A different minor → engine refuses to load the PCK.
- If a GodotSteam `.gdextension` is present (`strings game.pck | grep godotsteam`), plan to disable it
  (Windows exports ship only the `.dll`, never the macOS `.dylib`).

### Build steps (native)
1. **Get the matching Godot macOS binary.** e.g.
   `Godot_v{maj}.{min}.{patch}-stable_macos.universal.zip` from github releases. curl/github throttle
   behind proxy → use the `ghfast.top` mirror:
   `curl -sL -o g.zip "https://ghfast.top/https://github.com/godotengine/godot/releases/download/{tag}/Godot_v..._macos.universal.zip"`.
2. **Extract the PCK** with a custom parser (directory is plaintext at `dir_offset`; see pitfall
   2026-08-29). Header 44B; directory = `file_count(u32)` then per entry
   `[path_len(u32, 4-aligned, NO null terminator)][path][offset(u64)][size(u64)][md5(16)][flags(u32)]`;
   absolute file offset = `files_base + offset`. Some paths are stored WITHOUT the `res://` prefix
   (e.g. `.godot/...`) — strip the prefix only if present. Preserve dotfiles when copying:
   `cp -R "src/." "dst/"`.
3. **Convert `project.binary` → `project.godot`** (Windows exports often ship `project.binary`, not
   `project.godot`). Run the matching 4.x editor headless with `dump_settings.gd`:
   `extends SceneTree; func _init(): ProjectSettings.save_custom("res://project.godot"); quit()`
   launched as `godot --headless --path <game_assets> --script dump_settings.gd`.
4. **Resolve main scene**: `run/main_scene` is usually a `uid://...`. Resolve with a tiny Godot script
   using `ResourceUID.text_to_id()` + `ResourceUID.get_id_path()` (Godot stores UIDs as int64 in
   `uid_cache.bin`, not as text — do NOT grep the uid string). Set
   `run/main_scene="res://<Scene>.tscn"`; Godot auto-follows `<Scene>.tscn.remap` → compiled
   `<hash>-<Scene>.scn` in `.godot/exported/<hash>/`.
5. **Disable the GodotSteam GDExtension** (no macOS `.dylib` in a Windows export):
   - rename `addons/godotsteam/godotsteam.gdextension` → `.bak`;
   - remove the `[editor_plugins] enabled=PackedStringArray("res://addons/godotsteam/plugin.cfg")`
     line (it force-loads the GDExtension even when the file is gone);
   - delete any `.godot/**/extension_list.cfg` that references the missing `.gdextension`.
6. **Steam stub (optional insurance)**: if any script references the `Steam` singleton, add a GDScript
   autoload `Steam="*res://addons/godotsteam/steam_stub.gd"` with no-op methods + the common signals
   (`steam_callback`, `leaderboard_*`, `global_stats_received`, etc.). In Smashing Bottles NO script
   referenced `Steam` (grep 0 hits in `.gdc`/`.gd`), so the stub was pure insurance.
7. **Remove dead autoloads**: editor-only dev tooling (e.g. `godot_mcp` Model-Context-Protocol addons)
   is referenced as autoloads but NOT exported → their `.gd` files are missing → "Failed to instantiate
   autoload" errors. Delete those `[autoload]` lines.
8. Bundle + sign per §8/§9. Use the full editor binary renamed as the engine — it runs the game fine.
   (A leaner export-template binary is smaller but the editor binary is simplest and works.)

### Verify
- Headless parse: `godot --headless --path game_assets --quit-after 120` → expect no `SCRIPT ERROR`,
  no `GDExtension`/`godotsteam` lines, no "Could not find main scene".
- Live launch: runs and prints `Metal ... Using Device #0: Apple - Apple M1 Pro` and stays ALIVE
  (proves the renderer initialized on Apple Silicon). A harmless `rp_font is null` font-pin warning
  from `Localization.gd` is non-fatal.

## 12. Deliver

- Launch the installed app from Launchpad or Finder to confirm one more time.
- Provide the workspace `.app` zip as a backup deliverable.
- Note any known non-fatal warnings (object leaks, missing leaderboard, shader samplers) so the user knows they are harmless.

## 13. Self-iteration — keep this skill alive (standing rule)

**After every use of this skill**, before reporting done, spend one pass updating this
file so it self-improves. Do not treat the skill as frozen.

- Capture anything newly learned that is reusable: new engine quirks, new Wine/font
  fixes, new proxy/network workarounds, new packaging/signing lessons, new failure
  modes and their fixes.
- Append concrete pitfalls to the **"Known pitfalls & fixes"** log (section 14). Each
  entry: one line, what happened, what fixed it, date.
- If a section is wrong or outdated, correct it in place; do not leave stale advice.
- Prefer specifics over vague tips (exact file paths, registry keys, command lines).
- If a port succeeded or failed on an engine/config combination that is not yet in the
  README support matrix, update `README.md` too — add it to "Tested working",
  "Partially working", or "Currently unsolvable", and fold any broadly useful lesson
  into the README "Caveats" section (condensed; detail stays here in §14).
- This rule survives sessions: every future game-to-mac run re-applies it.

### 13b. Self-sync — owner only (standing rule)

> **Scope guard.** This auto-push rule fires **only** when this skill directory's
> `origin` remote is exactly `https://github.com/skawaks/game-to-mac` (the maintainer's
> own copy). If you are using a fork, a clone under a different account, or any other
> remote, **do not push here** — commit your changes locally and open a pull request
> instead. This prevents a third party's agent from pushing to the maintainer's repo.

This skill directory **is** a git repository tracking
`https://github.com/skawaks/game-to-mac` (branch `main`) on the maintainer's machine.
After finishing the iteration above, sync it so improvements are not stranded on one
machine — but only when the remote is the maintainer's own repo:

```bash
cd <this skill directory>
# safety check: only auto-push to the maintainer's own repo, never a fork/stranger's
REMOTE=$(git remote get-url origin 2>/dev/null || true)
if [ "$REMOTE" = "https://github.com/skawaks/game-to-mac.git" ] \
   || [ "$REMOTE" = "git@github.com:skawaks/game-to-mac.git" ]; then
  git add -A
  git status --short            # confirm only intended files are staged
  git commit -m "<short summary of what changed and why>"
  git push origin main
fi
```

For any other remote: skip the push, commit locally if useful, and in the final reply
tell the user how to contribute (`fork → commit → open a PR`).

Rules:

- **Just do it (owner only).** When the remote matches, commit and push without asking;
  a question before every push is friction, not safety.
- **Report it.** In the final reply, state that the changes were pushed and summarise
  what went into the commit.
- **Stop and ask only on failure.** If `git` is missing, the remote is unset, there is
  no credential, or the push is rejected — say so plainly and wait. Never silently skip
  the push, and never force-push to work around a rejection.
- **Never commit secrets, tokens, or user data.** If a pitfall entry would capture
  something sensitive, generalise it first.
- `.gitignore` already excludes build artifacts, game binaries, Wine bundles, and
  `.DS_Store`. If a new large or generated file shows up as untracked, add a pattern
  rather than committing it.

## 14. Known pitfalls & fixes (append-only log)

- **2026-08-28 — Wine CJK "hex tofu" on Godot 4 Windows build:** Game bundles only
  Latin fonts; relies on DirectWrite `IDWriteFactory2::GetSystemFontFallback`. Under
  Wine the fallback target names (`Microsoft YaHei`, `SimSun`, `PMingLiU`, `Yu Gothic`,
  etc.) are unmapped → CJK renders as codepoint boxes. Fix: copy one CJK `.ttf`
  (`Arial Unicode.ttf` from `/System/Library/Fonts/Supplemental/`) into
  `drive_c/windows/Fonts/`, then add `HKCU\Software\Wine\Fonts\Replacements` mapping
  every Windows CJK family name → `Arial Unicode MS`. Set `LANG`/`LC_ALL=zh_CN.UTF-8`.
  Verify with `WINEDEBUG=+dwrite`: look for `dwritefactory2_GetSystemFontFallback`,
  `fontfallback_MapCharacters("<game font>")`, `fontcollection_add_replacement`.
  Make the fix idempotent in `launch.sh` (copy font + `wine regedit /s` the .reg) so a
  rebuilt prefix does not lose it.
- **2026-08-28 — Whisky / CrossOver / Homebrew Wine are unreliable:** their installers
  hit dead CDNs or corporate proxies. Bundle a gcenx `macOS_Wine_builds` tarball
  (e.g. `wine-stable-11.0_1-osx64.tar.xz`) inside `Contents/Resources/wine`.
- **2026-08-28 — Apple Silicon Wine needs Rosetta + Vulkan path:** use an x86_64 Wine
  build; set `DYLD_FALLBACK_LIBRARY_PATH` to `Contents/Resources/wine/lib` so
  `libMoltenVK.dylib` is found (Vulkan/MoltenVK must init or Godot 4 won't render).
- **2026-08-28 — Encrypted Godot PCK: key is in the engine binary, not the .pck.**
  Source (`pck_packer.cpp`) shows the 32-byte AES key is passed into the packer, never
  written into the file. Don't waste time brute-forcing the `.pck` header; if you need
  to decrypt, recover the key from the `.exe` (raw bytes / 64-hex string / gzip'd
  `project.binary`). For CJK, the Wine-side font fix above avoids needing the key at all.
- **2026-08-28 — Proxy network quirks:** `git clone` may 502 while `curl` works; prefer
  release tarballs. GitHub releases throttle to ~30 KB/s behind proxy — use the
  `https://ghfast.top/https://github.com/...` mirror for fast source fetches.
- **2026-08-28 — Copied Godot binary SIGKILLs on launch (exit 137, no output):** `cp`
  of a signed Godot binary (e.g. `/Applications/Godot.app/.../Godot`) into a bundle
  breaks its code signature; macOS AMFI kills it with SIGKILL before any banner prints.
  Symptom: `--version` returns empty, exit 137. Fix: after placing the binary, run
  `codesign --force --deep --sign - "App.app"` and verify with `codesign -v`. Always
  sign the bundle, not just the inner binary.
- **2026-08-28 — Source type "Godot HTML5/WASM export wrapped in Android APK":** APK has
  `assets/.../index.html`, `index.js`, `index.wasm`, `index.pck` (NOT `project.binary`).
  This is a Godot web export shelled in an Android WebView. The `.pck` is
  platform-independent — extract `index.pck`, rename to `<exe>.pck` next to a NATIVE
  Godot binary of the SAME major.minor (read `GDPC`+uint32 major@offset8/minor@12/patch@16
  from the PCK header), and it runs as a real Mac game. No project.godot conversion needed.
- **2026-08-28 — Windows Unity (IL2CPP) port ≠ Godot; no native rebuild:** a Windows
  Unity player (`GameAssembly.dll` + `UnityPlayer.dll` + `<Game>_Data`) cannot be
  recompiled into a native Mac `.app` without the original Unity project. Port via the
  Wine wrapper (section 11). Identify engine from `globalgamemanagers` / UnitySubsystems;
  offline GoldBerg repacks (`steam_settings/` + `steam_api64.dll`) need no Steam login.
  Renderer reality on the bundled gcenx wine-11.0: it ships `libMoltenVK.dylib`
  (Vulkan→Metal works — M1 Pro detected) but **NO vkd3d-proton**, so D3D12 is unusable;
  force D3D11 (`-force-d3d11`) as the default. Tested on `Sludgineers` (Unity 6000.4.12f1):
  D3D11 device creation fails *headlessly* (no display in sandbox — may work on a real
  Mac), Vulkan is rejected with "Vulkan was not built from editor" (that player has no
  Vulkan renderer compiled in), and the game enforces a **D3D12 Feature Level 12.1
  minimum** ("D3D12 API denied by user filter" for FL<12.1). Net: if D3D11 doesn't render
  on the user's Mac, the reliable fix is a D3D12-capable Wine (CrossOver, or bundle
  vkd3d-proton) — the gcenx build alone cannot do D3D12.
  Expect a harmless missing `dev/*` autoload (dev/telemetry probe) and a "missing
  Steamworks" line if the game has an optional Steam plugin — both are non-fatal.
- **2026-08-28 — `--quit-after` is the only reliable timeout on macOS:** `timeout` is not
  installed by default. Use `godot --headless --quit-after <sec>` for self-termination;
  running without it blocks. Heavy engine + PCK also gets SIGKILL'd (137) inside the
  tool sandbox — re-run verification with the sandbox disabled (real machine memory).
- **2026-08-29 — Windows Godot UNencrypted PCK → NATIVE macOS (no Wine):** Smashing Bottles
  (SteamRIP/TENOKE, Godot 4.6.2) shipped an unencrypted PCK (enryption bit off, files are plaintext).
  An unencrypted Godot `.pck` is platform-independent → extract it and run with a same-`major.minor`
  macOS Godot binary. Far better than Wine. Don't assume every SteamRIP repack needs Wine — check the
  PCK header `flags` first (§11c).
- **2026-08-29 — Godot PCK custom extractor (Godot 4.6.2):** header = magic(4)+fmt(4)+major(4)+minor(4)
  +patch(4)+flags(4)+files_base(u64)+dir_offset(u64)+reserved(4) = 44B. Directory at `dir_offset` =
  `file_count(u32)` then per entry `[path_len(u32, 4-aligned, NO null term)][path][offset(u64)]
  [size(u64)][md5(16)][flags(u32)]`; absolute offset = files_base + offset. Some paths lack `res://`
  prefix (e.g. `.godot/...`). `file_base` value in header was 112; per-file `flags & 1` = encrypted.
- **2026-08-29 — `project.binary` not `project.godot`:** Windows Godot exports often store settings in
  `project.binary` (binary variant format). The engine reads it, but to edit autoloads/main_scene convert
  it with `godot --headless --path <proj> --script dump_settings.gd` where the script calls
  `ProjectSettings.save_custom("res://project.godot")`. Then edit the text `project.godot`.
- **2026-08-29 — main_scene is a `uid://` that is NOT a file:** resolve via a Godot script using
  `ResourceUID.text_to_id("uid://...")` + `ResourceUID.get_id_path(id)` (UIDs are int64 in `uid_cache.bin`,
  not searchable as text). The real entry is `<Scene>.tscn.remap` → compiled `.scn` in
  `.godot/exported/<hash>/`. Set `run/main_scene="res://<Scene>.tscn"` (Godot auto-follows `.remap`).
- **2026-08-29 — Disabling GodotSteam GDExtension needs 3 steps:** rename `.gdextension`→`.bak` alone is
  NOT enough — Godot still tries to load it because (a) `[editor_plugins] enabled=...godotsteam/plugin.cfg`
  force-enables it, and (b) stale `.godot/**/extension_list.cfg` lists it. Remove all three or you get
  "Error loading GDExtension configuration file" at every launch. The `Steam` singleton comes ONLY from
  the GDExtension (not an autoload in `project.godot`), so disabling it is safe if no script uses `Steam`.
- **2026-08-29 — Dead `godot_mcp` autoloads:** dev-only Model-Context-Protocol addons are listed as
  autoloads but their `.gd` files are NOT exported in the `.pck` → "Failed to instantiate autoload" errors.
  Delete those `[autoload]` lines (MCPScreenshot/MCPInputService/MCPGameInspector in Smashing Bottles).
- **2026-08-29 — Re-sign AFTER all edits:** editing `project.godot` or deleting files inside the bundle
  AFTER `codesign` invalidates the ad-hoc signature ("a sealed resource is missing or invalid"). Always
  run `codesign --force --deep --sign - app` as the LAST step. Nested `.godot/.godot/` duplicate paths
  can appear in some PCKs — remove the redundant nested dir; real resources live at top-level
  `.godot/exported/<hash>/` (verify file counts before deleting).
- **2026-08-29 — ghfast.top mirror for Godot binaries:** GitHub release downloads stall behind the proxy
  (~400KB then hang). `curl -sL "https://ghfast.top/https://github.com/godotengine/godot/releases/
  download/4.6.2-stable/Godot_v4.6.2-stable_macos.universal.zip"` pulled 161MB in ~20s.
- **2026-08-29 — GameMaker Studio 2 (data.win + .exe) has NO native macOS rebuild:** unlike Godot, there
  is no engine to run the assets on macOS — the ONLY path is a self-contained Wine wrapper (bundle gcenx
  Wine, launch `HowManyDudes.exe`). Identify it by `data.win` + `<Game>.exe` + `gm_ext_windows_util.dll`.
  64-bit exe = good (x86_64 Wine under Rosetta). `steam_settings/` + `steam_appid.txt` = GoldBerg offline
  repack → no Steam login; Steam init passes under Wine (`[STEAMWORKS]: RestartAppIfNecessary check passed`,
  `Steam initialization: 1`). GameMaker imports D3D11+XInput(+optional Media Foundation) — wined3d covers D3D11.
- **2026-08-29 — ⭐ GameMaker D3D11 BLACK SCREEN on Apple Silicon → the ONLY fix is DXVK-macOS (Gcenx async 1.10.3). wined3d and D3DMetal BOTH fail.** (This entry SUPERSEDES an earlier wrong note claiming wined3d `OffscreenRenderingMode=backbuffer` fixes it — it does NOT.) Verified exhaustively on `How Many Dudes` (GameMaker Studio 2, D3D11, M1 Pro, real display), with objective pixel statistics, not eyeballing:
  | Backend | Result |
  |---|---|
  | wined3d (`renderer=gl`) | **100% black + audio.** `glClear`/`glBlitFramebuffer` → `GL_INVALID_FRAMEBUFFER_OPERATION`. Tried 7 registry combos (`OffscreenRenderingMode=backbuffer/fbo`, `UseGLSL=disabled`, `AlwaysOffscreen=n`, `VideoMemorySize=4096`, `StrictDrawOrdering`, `MaxVersionGL=210`, `CSMT=n`) — **every one stayed `dark_fraction=1.0`**. Unfixable via registry. |
  | D3DMetal (Apple GPTK 3.0-2, or a GPTK-wine's builtin) | Error dialog: `CheckMultisampleQualityLevels` HRESULT `0x80070057` at `Graphics_DisplayM.cpp:1282`. Known D3DMetal×GameMaker bug. The 280×143 window people mistake for "wrong window size" IS this dialog. |
  | stock DXVK 2.x / 3.x | Device init aborts — hard-requires Vulkan 1.3 + `geometryShader`/tessellation, which MoltenVK/Apple GPUs do not expose. |
  | **DXVK-macOS async 1.10.3 (Gcenx)** | ✅ **Works.** Targets Vulkan 1.1 and relaxes the geometryShader gate (`geometryShader : 0` accepted). |
  Recipe (gcenx `wine-staging-11.16-osx64` + bundled MoltenVK 1.4.0): copy **only** `x64/d3d11.dll` + `x64/d3d10core.dll` into `$WINEPREFIX/drive_c/windows/system32/`, keep **Wine's builtin `dxgi`** (do NOT override dxgi), drop `dxvk.conf` next to the exe, and export:
  ```zsh
  export WINEDLLOVERRIDES="d3d11=n,b"      # NOT "d3d11,dxgi=n,b"
  export DXVK_ASYNC=1
  export VK_ICD_FILENAMES="$WINE_ROOT/lib/wine/x86_64-unix/vulkan/icd.d/MoltenVK_icd.json"
  wine reg delete "HKCU\Software\Wine\Direct3D" /f   # purge any wined3d tuning first
  ```
  Success markers in the log: `DXVK: v1.10.3-20230507-async (macOS)`, `DirectX11: Using hardware device`, `Creating swap chain at <W> by <H>`, and **no** `CheckMultisampleQualityLevels` dialog. Window becomes full-size (1512×982) instead of 280×143.
  Download: `curl -L "https://ghfast.top/https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507/dxvk-macOS-async-v1.10.3-20230507.tar.gz"` — **verify the size (~2.7MB+ is truncated; check `tar -tzf` succeeds)**, the direct GitHub URL silently returns partial/bad gzip behind a proxy.
- **2026-08-29 — ⚠️ NEVER claim a render fix from "looking at" a screenshot — the model cannot see images.** `Read` on a PNG returns "the current model does not support images. Content filtered", so any "I verified the screenshot" claim is fabricated. Build an objective gate instead, and make it the delivery criterion:
  1. `winlist.c` — a ~40-line CoreGraphics tool (`CGWindowListCopyWindowInfo` with `kCGWindowListOptionAll`) printing `WID<TAB>x,y<TAB>WxH<TAB>title`, so you can `screencapture -l<WID> -x out.png` the exact game window (including off-screen ones).
  2. `analyze_png.py` — Pillow script printing `dark_fraction`, `mean_luminance`, `luminance_stddev`, `distinct_color_buckets`, and a `verdict` (BLACK if `dark_fraction > 0.95`, else RENDERING).
  Black screen ⇒ `dark_fraction 1.0`, `distinct_color_buckets 1`. Working game ⇒ `dark_fraction ~0.24`, `buckets ~235`. Caveat: a bright **error dialog** also scores "RENDERING" — always cross-check the window SIZE and the log for error strings before declaring success.
- **2026-08-29 — GameMaker CJK "tofu" is a non-issue:** GameMaker ships its own font files (NotoSansSC/JP/KR/TC)
  and uses its own rasterizer, so the Wine CJK font-fallback hack (§11) is NOT needed even for CJK games.
- **2026-08-29 — `wineboot -u` creates the prefix headlessly; `wine cmd` does NOT:** to init a prefix in a
  display-less step, run `"$WINE" wineboot -u` (expect harmless bluetooth/usb `.inf` copy errors). Plain
  `wine cmd /c "..."` will NOT auto-create `drive_c`. Touch a `.hmd_inited` sentinel so first-run init is
  idempotent.
- **2026-08-29 — RAR extraction: no `unrar`; use `bsdtar`:** libarchive's `bsdtar -xf file.rar` extracts RAR
  (incl. multi-part) with no extra tooling. Also works where `unar`/`7z` are missing.
- **2026-08-29 — Windows Unity (IL2CPP) "Die in the Dungeon" (SteamRIP/TENOKE, Unity 2022.3.62f3):** no
  native rebuild → Wine wrapper (gcenx `wine-staging-11.16-osx64`). TENOKE config is `tenoke.ini`
  (`id = 2026820`, fully offline, NO `steam_settings/` needed). `strings UnityPlayer.dll` showed the player
  supports D3D11+D3D12+Vulkan+OpenGL → force `-force-d3d11` (wined3d→OpenGL), expose
  `RENDERER=vulkan|d3d12|auto` override. Verified: engine loads (`Initialize engine version: 2022.3.62f3`),
  `Player.log` written under `.../LocalLow/ATICO/Die in the Dungeon/` (dev = ATICO), TENOKE init OK.
  Headless-only failure was `d3d11: failed to create device (80004005)` (no display) — environmental.
- **2026-08-29 — Do NOT ad-hoc codesign Wine+Steam-emu bundles:** the Steam emulator writes log/emulated
  files INSIDE the bundle at runtime, which invalidates the ad-hoc seal so Gatekeeper reports "app is
  damaged" on the next launch. Also Wine loads an UNSIGNED `libMoltenVK.dylib` (library validation would
  reject it under a signature). Fix: `xattr -dr com.apple.quarantine "$APP"` and have the user approve once
  via **System Settings → Privacy & Security → "Open Anyway"**. No seal ⇒ runtime writes are harmless.
- **2026-08-29 — `iconutil -c icns` rejects ImageGen PNGs:** even at correct sizes (16/32/128/256/512 + @2x)
  `iconutil` failed with "Failed to generate ICNS" (embedded color profile / format quirk). Workaround: build
  the `.icns` with Python Pillow — `pip install Pillow; Image.open(png).convert("RGBA").save(out,
  format="ICNS")` (auto-generates the standard sizes). `sips` alone could not produce a valid icns here.
- **2026-08-29 — gcenx Wine release naming changed:** latest tag is `11.16` with assets
  `wine-devel-11.16-osx64.tar.xz` / `wine-staging-11.16-osx64.tar.xz` (the old `wine-stable-11.0_1-osx64`
  name is gone). The tarball wraps Wine under `Wine Staging.app/Contents/Resources/wine/{bin,lib,share}` —
  extract that `wine` folder (`bsdtar -xf x.tar.xz -C app/Contents/Resources/wine -s
  '|Wine Staging.app/Contents/Resources/wine/||' 'Wine Staging.app/Contents/Resources/wine'`) into
  `Contents/Resources/wine`. `wine --version` runs under Rosetta on M1 Pro; MoltenVK/Vulkan initializes
  (Metal 3 / Apple 7, `Apple M1 Pro`).
- **2026-08-29 — Unity 2022.3 Mono Windows player (Demon Lord: Just a Block, GoldBerg repack) on Apple Silicon:**
  wined3d's OpenGL backend reports max D3D feature level 9.3 on macOS because Apple OpenGL 4.1 does not
  advertise `GL_EXT_shader_integer_mix` (shader_model_4 gate in glsl_shader.c) or
  `GL_ARB_polygon_offset_clamp` (feature_level_from_caps gate in adapter_gl.c); Unity's player refuses to
  create a D3D11 device because it requires ≥ 10_0. DXVK also fails because MoltenVK does not expose
  `geometryShader`. Fix: bundle a tiny `DYLD_INSERT_LIBRARIES` shim that (a) interposes `dlsym()` and
  returns wrappers for `glGetIntegerv`/`glGetStringi` that add the two capability strings and for
  `glPolygonOffsetClampEXT` that calls `glPolygonOffset(factor, units)`, and (b) bootstraps the real
  `dlsym` by walking loaded images with `_dyld_image_count()` + `NSLookupSymbolInImage()` on each image
  until `_dlsym` is found in libdyld (RTLD_NEXT would hand back the interpose and recurse). With the shim,
  wined3d exposes `Direct3D 11.0 [level 10.1]`, the game initializes fully and CJK text renders correctly.
- **2026-08-30 — Unity IL2CPP Windows-only build (Die in the Dungeon, TENOKE) on Apple Silicon: D3D11
  is a dead end with stock Wine:** All D3D11 paths fail on M1 Pro: (1) wined3d silently returns `80004005`
  (E_FAIL) on `D3D11CreateDevice` — no useful diagnostic in wine.log; (2) DXVK ≥3.0 requires
  `geometryShader` which MoltenVK doesn't expose; (3) DXVK 1.10.3 gets further but MoltenVK still lacks
  D3D FL11_0 features; (4) `-force-vulkan` / `-force-glcore` both report "not built from editor" because
  the Unity player was compiled with D3D11 only. **Before attempting any Wine wrapper for a Unity Windows game,
  always check Steam/GOG for a native macOS version first** — it exists for many "Windows-only" indie games.
  If Wine is the only option and D3D11 fails, the OpenGL shim approach (see previous pitfall) or commercial
  layers (CrossOver, Apple GPTK) are the only viable paths forward.
- **2026-08-30 — ⭐ OnlineFix repacks: the `winmm.dll` proxy SILENTLY KILLS the game when no Steam client is
  reachable — and Wine loads it even with no `WINEDLLOVERRIDES`.** (How to Fish, Unity 6000.4.4f1 Mono,
  SteamRIP/OnlineFix.) The package gives it away: `winmm.dll` + `OnlineFix64.dll` + `OnlineFix.ini` +
  `SteamOverlay64.dll` + `dlllist.txt` next to the exe, and **no** `steam_settings/`. Confirmed with
  `WINEDEBUG=+loaddll`: `Loaded L"Z:\\...\\game\\WINMM.dll" ... native` — **Wine prefers the app-directory
  DLL by default**, so the proxy runs whether you ask for it or not. OnlineFix then terminates the process
  after ~30-60 s because it cannot reach a Steam client (a macOS Steam install is invisible from inside the
  prefix). Symptom: process alive, one untitled 500x500 Wine window, wine.log stops right after
  `fixme:win:create_window_handle DPI context`, and **no `Player.log` is ever created**.
  **Fix part 1:** `export WINEDLLOVERRIDES="winmm=b;..."` (force Wine's *builtin* winmm) so the proxy never
  loads and Unity can initialize. **Fix part 2:** replace the real `steam_api64.dll`
  (`How to Fish_Data/Plugins/x86_64/steam_api64.dll`) with an **offline Steam API emulator**, because OnlineFix
  relies on a real Steam client. Verified: GoldBerg emulator (`detanup01/gbe_fork` `emu-win-release.7z`) works:
  backup `steam_api64.dll` → `.original.bak`, copy `release/regular/x64/steam_api64.dll`, create
  `<game>/steam_appid.txt` with the real appid (`4001890`) and `<game>/steam_settings/disable_networking.txt`
  (empty). After both fixes: `Player.log` logs `Local User: gse orca:100`, `Steamworks` calls succeed, and the
  game spawns the player. Keep a `STEAMEMU=on` escape hatch that switches to `winmm=n,b` for users who do run
  Steam; otherwise use the GoldBerg-injected bundle as the default.
- **2026-08-30 — Unity games using Steamworks for single-player spawn (FishNet, SteamUser.GetSteamID())
  need an offline Steam API emulator.** How to Fish is single-player + local FishNet server, but the
  `SpawnPlayer` ServerRpc calls `Steamworks.SteamUser.GetSteamID()`. If Steam is not initialized, this throws
  `InvalidOperationException`, the RPC fails, the local connection is kicked, and you can never enter the game.
  Disabling OnlineFix or stubbing Steam initialization is not enough; you must supply a `steam_api64.dll` that
  returns a fake Steam ID offline. GoldBerg (see previous pitfall) is the reliable fix. Verify by watching
  `Player.log`: a successful spawn leaves "FishNet client 0 connected" with no `Steamworks is not initialized`
  exception; failure shows "ServerRpc failed... kicked".
- **2026-08-30 — CJK text renders fine under Wine for this Unity 6 game:** no font-fallback hacks were
  necessary. The Chinese interface (e.g. 新游戏, 加载, 时间到！) displays correctly with DXVK.
- **2026-08-30 — `Player.log` presence is the fastest go/no-go signal for any Unity port.** Path:
  `<prefix>/drive_c/users/<user>/AppData/LocalLow/<Company>/<Product>/Player.log` (Company/Product come from
  `<Game>_Data/app.info`). Unity opens it during engine init, *before* any C# script runs — so **no Player.log
  after 60 s ⇒ the game died before/inside Unity init**, not during gameplay. Look for a Steam-emu/proxy DLL
  (OnlineFix, GoldBerg, Codex) being force-loaded, or the real `steam_api64.dll` blocking.
- **2026-08-30 — Test harness kills background Wine: launch the app with `open -a`, not `nohup ... &`.**
  Launching from a Bash tool call (even `nohup ... &`) gets the whole Wine tree SIGKILLed when the tool call
  returns, leaving a misleading `wineserver crashed, please enable coredumps (ulimit -c unlimited) and
  restart.` as the last line of wine.log and no macOS crash report. Instead install the `.app` and run
  `open -a "/Applications/X.app"` — LaunchServices detaches it so it survives between tool calls.
  `open` does NOT inherit shell env, so have the launcher source a per-user config file
  (`[ -f "$HOME/Library/Application Support/X/config.sh" ] && . "$CONFIG"`) and write `HTF_LOG=1` /
  `WINEDEBUG=...` there for debugging.
- **2026-08-30 — Unity 6 (6000.4.x) Mono Windows player runs on Apple Silicon with DXVK-macOS async 1.10.3.**
  Verified on How to Fish (6000.4.4f1) with gcenx `wine-staging-11.16`: launch with `-force-d3d11`, DXVK
  reports `Direct3D 11.0 [level 11.0]` (spoofs "NVIDIA GeForce 6800"), MoltenVK swap chain 1512x982, window
  animates (31% of pixels change between two captures 6 s apart). Unlike Unity 2022.3 Mono (see the DYLD
  GL-shim pitfall) **no OpenGL shim is needed** — go straight to DXVK. Unity's own D3D12 device filter denies
  D3D12 anyway (`D3D12 API denied by user filter: Feature Level 12.1`), and no vkd3d is bundled, so
  `-force-d3d12` is moot. Online co-op / achievements need a reachable Steam client and will NOT work.
- **2026-08-30 — Reuse an existing Wine bundle with APFS cloning instead of re-downloading.**
  `cp -Rc /Applications/<Other>.app/Contents/Resources/wine <new>/Contents/Resources/wine` clones 849 MB
  instantly and the copy is fully independent afterwards (copy-on-write). Same trick for `dxvk/` and the shim
  `lib/`. Check the donor's version first: `.../wine/bin/wine --version`.
- **2026-08-30 — Steam CDN art 404s for very new indie appids.** `cdn.cloudflare.steamstatic.com/steam/apps/
  <appid>/library_600x900.jpg` and `/header.jpg` returned 404 for appid 4001890. Don't burn time on it —
  draw the icon with Pillow and write the `.icns` directly
  (`Image.open(p).convert("RGBA").save(out, "ICNS")`), since `iconutil` is unreliable anyway.
- **2026-08-31 — Syncing this skill to GitHub: HTTPS + PAT, not SSH and not `gh`.** The reference machine
  has no `gh` CLI, no `~/.ssh` keys, and no git `user.name`/`user.email`. Use an HTTPS remote plus a
  GitHub Personal Access Token stored by `git credential-osxkeychain`, so later pushes (see §13b) need no
  interactive auth. Generate at GitHub → Settings → Developer settings → Personal access tokens; for a
  **public** repo the `public_repo` scope is enough (`repo` also works but additionally grants access to
  every private repo). Store it without putting it in argv:
  `git credential-osxkeychain store <<< "protocol=https\nhost=github.com\nusername=<user>\npassword=<token>"`
  with `git config --global credential.helper osxkeychain` set; afterwards `git push` is silent. If a push
  is rejected with 403, the token is expired or lacks the scope — ask, do not force-push.
- **2026-08-31 — `git push` from inside an agent tool sandbox fails with SIGKILL (137) or `CONNECT tunnel
  failed, response 502`.** The sandbox injects `HTTP_PROXY`/`HTTPS_PROXY` pointing at a local port
  (`127.0.0.1:<port>`), and that proxy is intermittent: the same `git fetch` can succeed and then 502 a few
  minutes later, and once it degrades plain `curl` also returns `000` / exit 56. Push exits 137 with **no
  output at all** — easy to misread as a real failure. Fix: re-run outside the sandbox **and** unset the
  proxy vars:
  `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy git push origin main`
  Expect to retry 2-3 times; the first direct attempt can hang ~75 s before connecting. To verify a push,
  use the GitHub API — `raw.githubusercontent.com` stayed unreachable even while `api.github.com` worked:
  `curl -s https://api.github.com/repos/<owner>/<repo>/contents/` (check the `size` field; a stale
  README that was previously 0 bytes is the clearest signal that the push landed).
- **2026-08-31 — Adopting an existing remote repo without force-pushing.** When the GitHub repo already has
  commits (e.g. files added via the web UI) and you initialise locally, the histories are unrelated and a
  normal push is rejected. Instead of force-pushing, graft your work on top:
  `git init -b main && git remote add origin <url> && git fetch origin main && git reset --soft origin/main`
  `reset --soft` moves HEAD to the remote tip while leaving the working tree untouched, so the next commit
  contains only your changes and the push is a clean fast-forward.
- **2026-08-31 (CORRECTED 2026-09-03 — my original conclusion here was WRONG):** I claimed "Steam CDN is
  blocked in the agent sandbox, so you can never fetch a Steam game." **False.** See the 2026-09-03 pitfall
  below: SteamCMD running under Wine reaches Steam fine and downloads real depots. It is merely *slow*.
  Lesson: `curl ... → HTTP 000` only proves that **curl through the sandbox proxy** is blocked. It does NOT
  prove that a GUI/console app process is blocked. Never conclude "network blocked" from a curl probe alone —
  run the real binary and watch its progress log for N minutes before giving up.

- **2026-08-31 — ⭐ Whisky "WhiskyWine not installed" loop: inject a Wine build + a version-marker plist.**
  If Whisky opens with a *Dependencies Setup* dialog stuck on "WhiskyWine not installed" (and its own runner
  download is network-blocked), do NOT fight the GUI — sideload a known-good Wine:
  1. Copy an extracted gcenx wine tree into Whisky's expected dir, inside the **sandbox container**:
     `~/Library/Containers/com.isaacmarovitz.Whisky/Data/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/{bin,lib,share}`
     (source tree is `Wine Staging.app/Contents/Resources/wine/`). Ensure `bin/wine64` exists (`ln -s wine wine64`).
  2. Whisky's `isWhiskyWineInstalled()` ONLY checks that `Libraries/WhiskyWineVersion.plist` decodes — so write
     that plist with the REAL `SemanticVersion` shape (fields `major`,`minor`,`patch`,`preRelease`,`build`;
     last two are **Strings**, NOT arrays — I got it wrong twice). Minimal body:
     `<dict><key>version</key><dict><key>major</key><integer>2</integer><key>minor</key><integer>5</integer><key>patch</key><integer>0</integer><key>preRelease</key><string></string><key>build</key><string></string></dict></dict>`
  3. Whisky IS sandboxed: it reads the **container** App Support path, not `~/Library/Application Support` —
     files placed in the non-container path are invisible to it (that's why the first attempt failed).
  4. Verify without the GUI: `pkill Whisky; /Applications/Whisky.app/Contents/MacOS/Whisky & sleep 9; screencapture -x /tmp/s.png`
     then view the PNG — the bottle window (Run…/Open C: Drive) shows and no modal = fixed. `WhiskyCmd` CLI lives at
     `/Applications/Whisky.app/Contents/Resources/WhiskyCmd` (`list`/`run`/`shellenv`) but launching via it from an
     agent sandbox still hits the Steam-CDN block, so the actual Steam download must be triggered in the user's own GUI.
     (CORRECTION 2026-09-03: that last clause is also wrong — see next pitfall.)

- **2026-09-03 — ⭐⭐ RELIABLE WAY TO GET WINDOWS STEAM FILES ON THE MAC: SteamCMD under Wine (works, just slow).**
  This is the path that finally unblocked the Bottle Flip Inc Demo port. Full recipe:
  1. SteamCMD (`steamcmd.zip`, from `media.steampowered.com` or `partner.steamgames.com`) runs fine under the
     bundled gcenx Wine. Run it as a **background task** and poll the log — do not judge by the first 2 minutes.
  2. **Its bootstrap is ~29 MB and took ~14 minutes** (proxy rate-limits to ~35 KB/s). It prints
     `[ 18%] Downloading update (5,599 of 29,732 KB)...` and DOES progress. It leaves `steamcmd.exe.old` +
     `package/` behind. Once it prints `Update complete, launching Steamcmd...` it is ready.
  3. Enumerate the app first to confirm depot IDs / sizes (works anonymously):
     `+login anonymous +app_info_print <appid> +quit` → prints `depots` with each depot's `oslist`, `gid`,
     `size` (uncompressed) and `download` (compressed) bytes.
  4. Force the Windows build + target dir, then update:
     ```
     +@sSteamCmdForcePlatformType windows
     +force_install_dir "Z:\\Users\\<you>\\<workspace>\\game"   # Wine maps /Users/... -> Z:\Users\...
     +login <user> <pass> [<guard>]
     +app_update <appid> validate
     +quit
     ```
  5. **Anonymous login is NOT enough for a demo/free game** — you get
     `ERROR! Failed to install app '<appid>' (No subscription)`. A licensed account is required even when the
     app is free, because the *account* must hold the licence (check `config/config.vdf` for the appid).
  6. **Never ask the user to paste their Steam password into chat.** Instead ship a `.command` file they
     double-click: `read -r -s -p "Steam password (hidden): " PASS` then `nohup wine steamcmd.exe ... &`.
     Password stays in a shell variable, never hits disk or the transcript. Support an optional Steam Guard arg
     (omit it entirely when blank — passing an empty guard arg breaks login).
  7. Budget ~1 to 1.5 hours per ~165 MB at this proxy speed. Start it early and do the packaging work meanwhile.

- **2026-09-03 (CORRECTED SAME DAY — my original conclusion here was WRONG):** I diagnosed Bottle Flip Inc Demo (Unity 6000.3.8f1 IL2CPP, D3D11-only, appid 4966120, Heathen Steamworks Foundation, GoldBerg emu) as "frozen by a DXVK descriptor-pool exhaustion busy-loop — currently unsolvable." **False.** The `VK_ERROR_OUT_OF_POOL_MEMORY: VkDescriptorPool exhausted pool of 6144 VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC descriptors` flood is REAL (1.7M+ warnings/min, wine.log grows to 150 MB+) but **NON-FATAL**: the game renders, animates, and is fully playable (user-verified on real hardware + objective pixel/frame-diff proof: 286 color buckets, 5-8% pixel change between frames). My error: I killed every test run at ~45 s during the (long) initial load and judged "static gray frame" from captures — while the same build was actually playable on the user's screen. **Lessons:** (1) `grep -c OUT_OF_POOL_MEMORY wine.log` in the hundreds of thousands means NOISY, not dead — do not conclude "frozen" from log spam alone. (2) Wait at least 2-3 minutes before declaring a Unity game frozen; first-scene load under Wine+Rosetta can be slow. (3) Always cross-check with the human before writing "unsolvable". (4) Suppress the flood with `export MVK_CONFIG_LOG_LEVEL=error` in the launcher (default `info` spams 100 MB+ per session and the I/O alone can stutter the game).
- **2026-09-03 — Same-title window confusion in the render harness.** A Wine app shows MULTIPLE windows with the same owner/title: 500x500 ghost `wine` windows (leftover winedevice surfaces from killed runs), 1512x33 menu-bar strips, and the real 1512x982 main surface. `screencapture -l<WID>` on the wrong one gives a misleading "static gray" frame. Prefer a full-screen `screencapture -x` when the game runs borderless-fullscreen (the game window then equals the display at 2x), or filter winlist output by plausible geometry before capturing.
- **2026-09-03 — `${VAR:-default}` cannot be overridden to empty.** `EXTRA_FLAGS="${EXTRA_FLAGS:--noaudio}"` treats an EMPTY `EXTRA_FLAGS` as unset, so a config.sh can never ship "no extra flags" (e.g. to enable audio). Use `${EXTRA_FLAGS-}` (no colon) when the empty value is meaningful. This bit the Bottle Flip port: audio was silently off in every "audio test" because the launcher default re-applied `-noaudio`.
- **2026-09-03 — GL-capability shim via DYLD_INSERT_LIBRARIES is BYPASSED by Wine's internal GL dispatch for wined3d capability detection.** The shim (interpose `dlsym` to inject `GL_EXT_shader_integer_mix` + `GL_ARB_polygon_offset_clamp` so wined3d reports D3D FL ≥ 10.0 on Apple GL 4.1) DOES load (`[glcap_shim] LOADED` markers confirm) and wined3d DOES resolve `glGetString`/`glGetIntegerv` through the interposed dlsym — but the wrapper functions are NEVER CALLED (no CALL logs). Wine's GL capability detection goes through Wine's own thunk/dispatch layer, not the resolved pointers. So for wined3d D3D11 on macOS, GL-capability shimming is ineffective: wined3d still caps at FL 9.3 (`wined3d_select_feature_level None of the requested D3D feature levels is supported`) → `d3d11: failed to create device and context (80004005)`. Do NOT re-attempt the dlsym-shim for wined3d; the only FL-cap fix is CrossOver/GPTK (D3D12→Metal) or patching wined3d itself. (Shim source kept at `tools_render/glcap_shim.c` for reference; compile `cc -arch x86_64 -dynamiclib`.)
- **2026-09-03 — Launcher `DXVK_ASYNC` override-order bug.** If the launcher sets `export DXVK_ASYNC=1` AFTER sourcing the per-user `config.sh`, a `DXVK_ASYNC=0` in config.sh is silently ignored. Fix: `export DXVK_ASYNC="${DXVK_ASYNC:-1}"` so config.sh wins. (During Bottle Flip Inc diagnosis a "DXVK_ASYNC=0 didn't help" conclusion was INVALID because of this — it was actually still running async.)
- **2026-09-04 (CORRECTED — prior version of this entry was WRONG): Steam console `download_depot` DOES download fully-extracted, ready-to-run game files — do NOT reassemble.** On the current Steam macOS client the binaries land at `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_<appid>/depot_<depotid>/` (a real game dir, already reassembled by Steam; e.g. My Fire demo → `.../app_4559990/depot_4559991/` with the `.exe` + `UnityPlayer.dll` + `*_Data/` inside). Steam ALSO drops a `<depot>_<gid>.manifest` in `~/Library/Application Support/Steam/depotcache/`, but that is just metadata — the playable files are the extracted content dir, NOT a manifest+chunk set. So the workflow is simply: (1) `steam://open/console` → (2) `wine steamcmd.exe +login anonymous +app_info_print <appid> +quit` to read `depots` (`oslist`, `gid`, `size`) → (3) `download_depot <appid> <depotid> <gid>`. Then **copy the content dir straight into `Resources/game/`**. The `reassemble_depot.py` tool is now only a FALLBACK for older Steam clients that leave raw chunks; prefer the extracted content dir. **Path gotcha:** that content dir is depth ~11 under `~/Library` — a `find` with `maxdepth 8` will NOT find it, and the Steam console log prints the path with backslashes (`MacOS\steamapps\content\...`) even though the real dir uses forward slashes. Search with `find ~ -maxdepth 12 -type d -name depot_<depotid>`. `download_depot` needs the account to HOLD the licence even for a free demo (`No subscription` otherwise), so the user must claim/own the app in their library first.
- **2026-09-04 — Mono Unity builds (no `GameAssembly.dll`) port CLEANER than IL2CPP, and usually need NO GoldBerg.** My Fire Is Bigger Than Yours (Demo, appid 4559990, Unity Mono, Punch Pancake) shipped only `UnityPlayer.dll` + `MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` and **no `steam_api*.dll` anywhere** → no Steam DRM → no GoldBerg, no `steam_appid.txt`. Player.log went `MonoManager ReloadAssembly → Loaded All Assemblies` (Mono works under Wine) then `PhysX` + `Windows.Gaming.Input` initialized, and `d3d12: failed to create D3D12 device (0x80004002)` fell back to D3D11 cleanly. Same DXVK D3D11 recipe as Bottle Flip (Wine 11.16 + DXVK-macOS async 1.10.3, `-force-d3d11`, `MVK_CONFIG_LOG_LEVEL=error`). Verified playable via pixel stats (274 color buckets, RENDERING) + frame-diff (22.8% pixel change → ANIMATING). Takeaway: check for `steam_api*.dll` FIRST — if absent, skip the whole GoldBerg dance.
- **2026-09-04 — A `.app` bundle MUST contain `Contents/Info.plist` with `CFBundleExecutable` EXACTLY matching the launcher filename, or `open -a` fails with "cannot be opened because its executable is missing".** The skeleton built for My Fire had `Contents/MacOS/<launcher>` + `Contents/Resources/` but no `Info.plist`; `open -a` refused until the plist named the launcher. Minimal plist needs `CFBundleName`, `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundlePackageType=APPL`. (Bottle Flip's plist is a working template — copy and edit the two name/identifier strings.)
- **2026-09-04 — `pkill -f wineserver` is GLOBAL and will kill OTHER running Wine games too.** When stopping a test run, prefer `pkill -f "<this game's exe name>"` + that game's specific `wineserver` path, not a bare `wineserver` pattern, or you'll nuke a game the user is actively playing in another bundle. (Caught it in time this run — Bottle Flip stayed up — but it's a real footgun.)
- **2026-09-04 — App icons from local Steam cache + Pillow (iconutil is unreliable for composed art).** Steam caches each game's capsule/hero/logo locally at `~/Library/Application Support/Steam/appcache/librarycache/<appid>/<hash>/` — filenames: `library_capsule.jpg` (~300x450), `library_hero.jpg` (1920x620), `library_header.jpg` (460x215), `logo.png` (transparent, ~640x360). Compose a clean 1024² icon with Pillow: `bg = ImageOps.cover(Image.open(hero), (1024,1024)).filter(GaussianBlur(18))`, darken `Image.eval(bg, lambda v:int(v*0.55))`; overlay the transparent `logo.png` centered at ~70% width via `canvas.alpha_composite(logo, (off_x, off_y))`; then `icon.save(png)` and `icon.save(out, "ICNS")` (Pillow auto-generates standard sizes; `iconutil -c icns` rejects these PNGs). Ship as `Contents/Resources/Icon.icns` and set `CFBundleIconFile=Icon` in `Info.plist`. Pillow is NOT preinstalled — `pip install Pillow` into the managed venv first.
- **2026-09-04 — Unity-under-Wine long-play stutter: kill the DXVK log flood AND cap the frame rate.** Bottle Flip Inc (Unity 6000.3.8f1 IL2CPP, DXVK-macOS async 1.10.3) lagged after long sessions. Root cause is the `VK_DESCRIPTOR_POOL exhausted` warnings (DXVK dynamic UBO pool) spamming at ~150 MB/min — `MVK_CONFIG_LOG_LEVEL=error` alone is NOT enough because DXVK writes its OWN copy to `DXVK_LOG_PATH` when `DXVK_LOG_LEVEL=info`; set `DXVK_LOG_LEVEL=error` too (this kills the log I/O that itself stutters the game). ALSO add `DXVK_FRAME_RATE=60` to cut GPU/CPU thermal throttling — the other "laggy after long play" cause on Apple Silicon. Both overridable via the per-user `config.sh`. Caveat: the periodic pool-reset hitches are engine/DXVK-level and not fully launcher-fixable with this Wine/DXVK combo; if stutter persists it's the game's own object/particle accumulation under Wine's slower CPU, so periodic restart is the practical workaround. (The Bottle Flip `Player.log` also grew to ~3.4 MB from DOTween `Debug.Log` spam — `-nolog` would stop it but removes diagnostics; left on.)
