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
- This rule survives sessions: every future game-to-mac run re-applies it.

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
  Expect a harmless missing `dev/*` autoload (dev/telemetry probe) and a "missing
  Steamworks" line if the game has an optional Steam plugin — both are non-fatal.
- **2026-08-28 — `--quit-after` is the only reliable timeout on macOS:** `timeout` is not
  installed by default. Use `godot --headless --quit-after <sec>` for self-termination;
  running without it blocks. Heavy engine + PCK also gets SIGKILL'd (137) inside the
  tool sandbox — re-run verification with the sandbox disabled (real machine memory).
