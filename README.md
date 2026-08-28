# game-to-mac

Port a non-macOS game (Android APK, Godot project, or loose assets) into a runnable macOS `.app` bundle installed in `/Applications`.

`game-to-mac` is a [WorkBuddy](https://www.workbuddy.ai) skill. It encodes an end-to-end workflow for turning Godot Engine 4.x Android builds (and related formats) into first-class macOS apps — handling binary project extraction, GDExtension/platform-library stubbing, `.godot` cache preservation, `.app` packaging, ad-hoc code signing, and mandatory pre-delivery testing.

> Default assumption: the source is an **Android APK built with Godot Engine 4.x**. The workflow also adapts to other Godot export formats, loose project folders, Windows Godot executables (Wine wrapper), and Windows Unity IL2CPP standalones.

---

## Table of contents

- [What it does](#what-it-does)
- [Supported sources](#supported-sources)
- [Installing the skill](#installing-the-skill)
- [Usage](#usage)
- [Workflow overview](#workflow-overview)
- [Known pitfalls & fixes](#known-pitfalls--fixes)
- [License](#license)

---

## What it does

`game-to-mac` automates the fiddly parts of porting a game to macOS:

- **Inspects** an APK to identify the Godot engine version and bundled plugins.
- **Extracts** assets and converts a binary `project.binary` into a text `project.godot`.
- **Fixes project settings** (main scene, autoloads, audio bus, icon) for the macOS runtime.
- **Stubs or disables** Android-only GDExtensions (e.g. GodotSteam) so the missing `.dylib` files don't crash the launch.
- **Preserves** the hidden `.godot/` cache (compiled scenes, UID cache, script class registry) — the #1 cause of broken ports.
- **Packages** a proper `.app` bundle with launcher, `Info.plist`, and generated `.icns` icon.
- **Installs** to `/Applications` and **ad-hoc signs** the bundle.
- **Tests** three ways (headless parse, live launch, render) before declaring success.
- **Falls back** to a self-contained Wine-wrapped `.app` for Windows Godot executables (encrypted `.pck`) and Windows Unity IL2CPP standalones.

---

## Supported sources

| Source type | Native Mac app? | Notes |
| --- | --- | --- |
| Android APK (Godot 4.x) | ✅ Yes | Primary path. Converts `project.binary` → `project.godot`. |
| Godot HTML5/WASM in APK | ✅ Yes | `.pck` is platform-independent; pair with a native Godot binary of the same version. |
| Loose Godot project folder | ✅ Yes | Skip APK extraction steps. |
| Windows Godot `.exe` + encrypted `.pck` | ⚠️ Wine wrapper | PCK AES key lives in the Windows binary, not the file. Wine-side CJK font fix avoids needing the key. |
| Windows Unity IL2CPP standalone | ⚠️ Wine wrapper | No native rebuild without the Unity project. Force D3D11; bundle MoltenVK Wine build. |

---

## Installing the skill

This skill runs inside WorkBuddy. Copy or clone it into your skills directory.

**User-level** (available across all projects):

```bash
cp -R game-to-mac ~/.workbuddy/skills/game-to-mac
```

**Project-level** (shared with a team on one project):

```bash
cp -R game-to-mac /path/to/project/.workbuddy/skills/game-to-mac
```

Alternatively, point WorkBuddy at this repo when importing a skill.

> Requires a desktop **Godot** editor installed at `/Applications/Godot.app` for conversion and testing. Wine-based ports bundle their own Wine build inside the app, so no system Wine is needed.

---

## Usage

Invoke the skill naturally in a WorkBuddy conversation:

- "Port this game to mac"
- "Make this APK run on mac"
- "Convert this APK to a mac app"
- "Install it in /Applications"
- "移植到 mac"

Provide the path to the source file (e.g. `game.apk`), and the skill drives the rest — extracting, converting, packaging, signing, and verifying.

---

## Workflow overview

1. **Inspect the source** — `unzip -l game.apk`, read `assets/_cl_` for engine version, list plugins.
2. **Extract assets** — `unzip` the `assets/*` tree and flatten.
3. **Convert `project.binary` → `project.godot`** — run a tiny `dump_settings.gd` SceneTree script under the desktop Godot editor.
4. **Fix project settings** — main scene, autoloads, audio bus, icon path.
5. **Handle GDExtensions** — prefer a GDScript stub, else disable the `.gdextension`.
6. **Decode `.gdc`** (if needed) — XOR-based identifier decoder for API-surface discovery.
7. **Preserve `.godot/` cache** — copy with `cp -R "src/." "dst/"` so dotfiles survive; restore from APK if the editor wiped them.
8. **Build the `.app`** — `Info.plist`, launcher script, generated `.icns`.
9. **Install to `/Applications`** and **ad-hoc sign** the whole bundle.
10. **Test** — headless parse, live launch, and render checks must all pass.
11. **Wine fallback** (Windows sources) — bundle a gcenx macOS Wine build, set up the prefix, fix CJK tofu, force the right renderer.
12. **Deliver** — launch once more, ship a `.app` zip backup, note non-fatal warnings.

See `SKILL.md` for the full command-level playbook.

---

## Known pitfalls & fixes

A running log of hard-won lessons (append-only). Each entry: what broke, what fixed it, date.

- **2026-08-28 — Wine CJK "hex tofu" on Godot 4 Windows build:** Game bundles only Latin fonts; relies on DirectWrite `IDWriteFactory2::GetSystemFontFallback`. Under Wine the fallback target names (`Microsoft YaHei`, `SimSun`, `PMingLiU`, `Yu Gothic`, etc.) are unmapped → CJK renders as codepoint boxes. Fix: copy one CJK `.ttf` (`Arial Unicode.ttf` from `/System/Library/Fonts/Supplemental/`) into `drive_c/windows/Fonts/`, then add `HKCU\Software\Wine\Fonts\Replacements` mapping every Windows CJK family name → `Arial Unicode MS`. Set `LANG`/`LC_ALL=zh_CN.UTF-8`. Verify with `WINEDEBUG=+dwrite`: look for `dwritefactory2_GetSystemFontFallback`, `fontfallback_MapCharacters("<game font>")`, `fontcollection_add_replacement`. Make the fix idempotent in `launch.sh` (copy font + `wine regedit /s` the .reg) so a rebuilt prefix does not lose it.
- **2026-08-28 — Whisky / CrossOver / Homebrew Wine are unreliable:** their installers hit dead CDNs or corporate proxies. Bundle a gcenx `macOS_Wine_builds` tarball (e.g. `wine-stable-11.0_1-osx64.tar.xz`) inside `Contents/Resources/wine`.
- **2026-08-28 — Apple Silicon Wine needs Rosetta + Vulkan path:** use an x86_64 Wine build; set `DYLD_FALLBACK_LIBRARY_PATH` to `Contents/Resources/wine/lib` so `libMoltenVK.dylib` is found (Vulkan/MoltenVK must init or Godot 4 won't render).
- **2026-08-28 — Encrypted Godot PCK: key is in the engine binary, not the `.pck`.** Source (`pck_packer.cpp`) shows the 32-byte AES key is passed into the packer, never written into the file. Don't waste time brute-forcing the `.pck` header; if you need to decrypt, recover the key from the `.exe` (raw bytes / 64-hex string / gzip'd `project.binary`). For CJK, the Wine-side font fix above avoids needing the key at all.
- **2026-08-28 — Proxy network quirks:** `git clone` may 502 while `curl` works; prefer release tarballs. GitHub releases throttle to ~30 KB/s behind proxy — use the `https://ghfast.top/https://github.com/...` mirror for fast source fetches.
- **2026-08-28 — Copied Godot binary SIGKILLs on launch (exit 137, no output):** `cp` of a signed Godot binary (e.g. `/Applications/Godot.app/.../Godot`) into a bundle breaks its code signature; macOS AMFI kills it with SIGKILL before any banner prints. Symptom: `--version` returns empty, exit 137. Fix: after placing the binary, run `codesign --force --deep --sign - "App.app"` and verify with `codesign -v`. Always sign the bundle, not just the inner binary.
- **2026-08-28 — Source type "Godot HTML5/WASM export wrapped in Android APK":** APK has `assets/.../index.html`, `index.js`, `index.wasm`, `index.pck` (NOT `project.binary`). This is a Godot web export shelled in an Android WebView. The `.pck` is platform-independent — extract `index.pck`, rename to `<exe>.pck` next to a NATIVE Godot binary of the SAME major.minor (read `GDPC`+uint32 major@offset8/minor@12/patch@16 from the PCK header), and it runs as a real Mac game. No `project.godot` conversion needed.
- **2026-08-28 — Windows Unity (IL2CPP) port ≠ Godot; no native rebuild:** a Windows Unity player (`GameAssembly.dll` + `UnityPlayer.dll` + `<Game>_Data`) cannot be recompiled into a native Mac `.app` without the original Unity project. Port via the Wine wrapper (section 11). Identify engine from `globalgamemanagers` / UnitySubsystems; offline GoldBerg repacks (`steam_settings/` + `steam_api64.dll`) need no Steam login. Renderer reality on the bundled gcenx wine-11.0: it ships `libMoltenVK.dylib` (Vulkan→Metal works — M1 Pro detected) but **NO vkd3d-proton**, so D3D12 is unusable; force D3D11 (`-force-d3d11`) as the default. Tested on `Sludgineers` (Unity 6000.4.12f1): D3D11 device creation fails *headlessly* (no display in sandbox — may work on a real Mac), Vulkan is rejected with "Vulkan was not built from editor" (that player has no Vulkan renderer compiled in), and the game enforces a **D3D12 Feature Level 12.1 minimum** ("D3D12 API denied by user filter" for FL<12.1). Net: if D3D11 doesn't render on the user's Mac, the reliable fix is a D3D12-capable Wine (CrossOver, or bundle vkd3d-proton) — the gcenx build alone cannot do D3D12. Expect a harmless missing `dev/*` autoload (dev/telemetry probe) and a "missing Steamworks" line if the game has an optional Steam plugin — both are non-fatal.
- **2026-08-28 — `--quit-after` is the only reliable timeout on macOS:** `timeout` is not installed by default. Use `godot --headless --quit-after <sec>` for self-termination; running without it blocks. Heavy engine + PCK also gets SIGKILL'd (137) inside the tool sandbox — re-run verification with the sandbox disabled (real machine memory).

---

## License

MIT — use it, fork it, improve it. Pull requests that extend the pitfalls log are welcome.
