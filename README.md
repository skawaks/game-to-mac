# game-to-mac

Port a non-macOS game — Android APK, Windows Godot/Unity/GameMaker build, or a loose
project folder — into a runnable macOS `.app` installed in `/Applications`.

This is a **skill**, not an application. It is a single `SKILL.md` playbook that an AI
coding agent reads and executes. There is nothing to compile and no runtime dependency
beyond the tools listed under [Requirements](#requirements).

Default assumption: the source is an **Android APK built with Godot Engine 4.x**. The
playbook detects other formats and routes them accordingly.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [Support matrix](#support-matrix)
- [Render verification](#render-verification)
- [Memory-leak verification & dxvk.conf](#memory-leak-verification--dxvkconf)
- [Caveats](#caveats)
- [License](#license)

---

## How it works

The core insight: **game assets are usually platform-independent; only the engine binary
is platform-specific.** A Godot `.pck` (or the `assets/` tree inside an APK) is just
packed resource data — the same bytes run on Windows, Linux, Android, or macOS. So the
port is mostly a matter of **pairing the assets with a macOS engine binary of a matching
version**, then cleaning up the platform-specific bits that no longer apply.

When no macOS engine exists to host the assets (closed-source Unity / GameMaker players),
the playbook falls back to **running the original Windows `.exe` through a self-contained
Wine bundle** shipped inside the `.app`.

### Route selection

```mermaid
flowchart TD
    A[Identify source] --> B{Engine?}

    B -->|Godot| C{PCK encrypted?}
    B -->|Loose Godot project| D
    B -->|Unity / GameMaker| E{Official macOS build<br/>on Steam / GOG?}

    C -->|No| D[Native route:<br/>pair assets with macOS Godot]
    C -->|Yes| E

    E -->|Yes| E2[Use the official build.<br/>Stop here.]
    E -->|No| G[Wine route:<br/>bundle Wine + graphics backend]

    D --> F[Bundle .app]
    G --> F
    F --> I[Install to /Applications + codesign]
    I --> J[3-way test:<br/>headless, live, render]
```

### Route A — native Godot (always preferred)

1. **Inspect** — `unzip -l game.apk`; read engine version from `assets/_cl_`; note
   plugins under `assets/addons/`.
2. **Extract** — pull out the `assets/*` tree and flatten it.
3. **Convert settings** — Android/Windows exports ship a binary `project.binary`. Run a
   three-line `dump_settings.gd` under a desktop Godot binary to emit a text
   `project.godot` you can actually edit.
4. **Fix project settings** — resolve `run/main_scene` (usually a `uid://` reference that
   must be resolved to a real `.tscn`), prune dead autoloads, set icon and audio bus.
5. **Neutralize platform-only extensions** — an Android export ships only `.so` files and
   a Windows export only `.dll` files. The macOS `.dylib` is simply absent, so the
   extension must be stubbed or disabled or the launch dies.
6. **Preserve the `.godot/` cache** — this is the single biggest cause of broken ports.
   It holds compiled `.scn` files, the UID cache, and the `class_name` registry. Opening
   the project in the desktop editor can silently wipe it.
7. **Bundle** — `Info.plist`, launcher script, generated `.icns`.
8. **Install and sign** — copy to `/Applications`, then ad-hoc `codesign` the whole bundle.
9. **Test three ways** — headless parse, live-alive check, and a render check that proves
   real pixels were drawn. All three must pass before you call it done.

### Route B — Wine wrapper (when there is no macOS engine)

1. **Check Steam/GOG for a native macOS build first.** Many "Windows-only" indie games
   have one. This beats every workaround below.
2. **Bundle a gcenx Wine build** inside `Contents/Resources/wine`. Do not depend on the
   user installing Whisky / CrossOver / Homebrew Wine — those sources break behind
   proxies and dead CDNs.
3. **Create a prefix** with `wineboot -u` (plain `wine cmd` will not create `drive_c`).
4. **Install the right graphics backend.** This is where nearly all the effort goes, and
   the correct choice depends on the engine — see the [support matrix](#support-matrix).
5. **Handle the repack layer.** GoldBerg / TENOKE are offline and fine. OnlineFix will
   silently kill the game unless you force Wine's builtin `winmm` and supply an offline
   Steam API emulator.

### Why the testing step is non-negotiable

A port can "launch" and still draw a black screen, or exit after 60 seconds because a
Steam emulator gave up. The playbook therefore requires objective evidence:
`Player.log` exists, the process is still alive after N seconds, and pixel statistics
prove non-black frames. **Never claim a render fix from eyeballing a screenshot** —
build a numeric gate instead.

---

## Requirements

Verified on **macOS with Apple Silicon (M1 Pro)**. Intel Macs should work but are not
the tested reference.

### Native Godot route

| Need | Notes |
| --- | --- |
| Godot binary | `/Applications/Godot.app`, or download a version-matched build. **Must match the game's `major.minor`** (patch may differ) or the engine refuses the PCK. |
| `unzip`, `bsdtar` | `bsdtar` handles RAR (including multi-part) with no extra tooling. |
| `codesign`, `xattr` | Xcode Command Line Tools. |
| Python + Pillow | For icon generation and pixel-statistics testing. `iconutil` is unreliable. |

### Wine route

| Need | Notes |
| --- | --- |
| Rosetta 2 | Apple Silicon runs the x86_64 Wine build under translation. |
| gcenx Wine build | ~849 MB per bundle. Reuse an existing one with `cp -Rc` (APFS clone, instant, copy-on-write). |
| MoltenVK | Ships with the gcenx build. This is the only Vulkan path — there is no vkd3d. |
| Disk space | Budget ~1 GB per ported game. |

### Network

GitHub release downloads often stall behind a proxy. Use the
`https://ghfast.top/https://github.com/...` mirror — it pulled a 161 MB Godot zip in
~20s where the direct URL hung after ~400 KB.

---

## Install

`game-to-mac` is a directory with no build step: `SKILL.md` (the playbook), this
`README.md`, a `.gitignore`, and a `LICENSE` (MIT). The playbook follows the common
"SKILL.md with YAML frontmatter" convention used by several agents, while this
`README.md` is the human-readable guide.

### Pick your agent's skills directory

Different agents use different folders. Copy or clone this repo into the right one:

```bash
# Claude Code
cp -R game-to-mac ~/.claude/skills/game-to-mac

# Codex
cp -R game-to-mac ~/.codex/skills/game-to-mac

# WorkBuddy
cp -R game-to-mac ~/.workbuddy/skills/game-to-mac
```

Or clone straight into place (replace the destination with your agent's skills folder):

```bash
# WorkBuddy example; adjust the path for Claude Code / Codex / your agent.
git clone https://github.com/skawaks/game-to-mac.git ~/.workbuddy/skills/game-to-mac
```

### If your agent expects a different skill entry file

Some agents read `README.md` as the skill instructions; this repo keeps the playbook in
`SKILL.md` and the docs in `README.md`. If your agent does not pick up `SKILL.md`
automatically, either:

- tell your agent to use `SKILL.md`, or
- copy `SKILL.md` over `README.md` inside the skill directory so the agent loads the
  playbook:

```bash
cd ~/.workbuddy/skills/game-to-mac   # or ~/.claude/skills/game-to-mac, etc.
cp SKILL.md README.md
```

Do that **only** inside your local copy; do not change the upstream repo's `README.md`.

---

## Usage

Just describe the goal and give a path:

- "Port this game to mac"
- "Make this APK run on mac"
- "Convert this APK to a mac app"
- "移植到 mac"

Then hand over the source file. The agent drives the rest — detection, extraction,
packaging, signing, verification.

---

## Support matrix

### Tested working

| Source | Route | Verified on | Result |
| --- | --- | --- | --- |
| Android APK, Godot 4.x | Native | Godot 4.x / Apple Silicon | ✅ Full native `.app` |
| Godot HTML5/WASM in APK | Native | `index.pck` + matching Godot binary | ✅ Full native `.app` |
| Loose Godot project folder | Native | — | ✅ Full native `.app` |
| Windows Godot, **unencrypted** PCK | Native | Smashing Bottles (Godot 4.6.2, M1 Pro, Metal 4.0 Forward+) | ✅ Full native `.app`, better than Wine |
| Windows Godot, **encrypted** PCK | Wine | `gamblers-table` (Godot 4, SteamRIP) | ⚠️ Runs via Wine; CJK needs the font fix |
| GameMaker Studio 2 (`data.win`) | Wine + **DXVK-macOS async 1.10.3** | How Many Dudes (M1 Pro) | ✅ Only working config — see [caveats](#caveats) |
| Unity 6 (6000.4.x) Mono | Wine + DXVK-macOS 1.10.3, `-force-d3d11` | How to Fish (6000.4.4f1) | ✅ No GL shim needed |
| Unity 6 (6000.3.x) IL2CPP, D3D11-only | Wine + DXVK-macOS 1.10.3, `-force-d3d11`, GoldBerg emu, `MVK_CONFIG_LOG_LEVEL=error` | Bottle Flip Inc Demo (6000.3.8f1, M1 Pro) | ✅ Playable, audio on; descriptor-pool warnings are non-fatal noise |
| Unity Mono (no `GameAssembly.dll`, no `steam_api*.dll`) | Wine + DXVK-macOS 1.10.3, `-force-d3d11`, `MVK_CONFIG_LOG_LEVEL=error` | My Fire Is Bigger Than Yours — DEMO (Punch Pancake, M1 Pro) | ✅ Cleanest port: no GoldBerg (no Steam DRM), D3D12 auto-falls-back to D3D11, Mono runtime works under Wine |
| Unity 6 (6000.3.x) Mono + **SOVEREIGN** repack, retail build | Wine + DXVK-macOS 1.10.3, `-force-d3d11`; reuse `wine/`+`dxvk/`+`prefix/` from a sibling port via `cp -Rc` | My Fire Is Bigger Than Yours (6000.3.7f1, appid 4428630, M1 Pro) | ✅ 60 FPS, D3D 11.0 [level 11.0] on Apple M1 Pro. SOVEREIGN is offline — no Steam client, no GoldBerg surgery. Retail ships NotoSansSC + Unity.Localization, so Simplified Chinese works (demo does not) |
| Unity 2022.3 Mono | Wine + DYLD OpenGL shim | Demon Lord: Just a Block | ✅ wined3d reports D3D 11.0 level 10.1 |
| Unity 6 (6000.0.x) IL2CPP, **Microsoft Store / MSIX (GDK)** build | Wine + DXVK-macOS 1.10.3, `-force-d3d11`, `winmm=b`; **startup `.mp4`s moved out of `StreamingAssets/video/`** | Heroes of Might and Magic: Olden Era (6000.0.66f1, M1 Pro) | ✅ D3D 11.0 [level 11.0] on Apple M1 Pro, reaches the main menu and renders. `XGameRuntime`/"Platform Store is not running" errors are non-fatal. Cost: **no in-game cinematics** (see [caveats](#caveats)) |

### Partially working

| Source | Status |
| --- | --- |
| Unity IL2CPP, TENOKE repack | Engine initializes, `Player.log` written, repack init OK. Rendering not confirmed headless — `d3d11: failed to create device (80004005)` is usually just "no display in sandbox". Must be confirmed on a real Mac. |

### Currently unsolvable

Know these before you burn hours on them.

| Case | Why it's stuck |
| --- | --- |
| **Encrypted Godot PCK, key unavailable** | The 32-byte AES key lives in the engine binary, never in the `.pck`. No key, no decrypt, no native rebuild. Wine is the only route. |
| **Unity IL2CPP, D3D11-only, Apple Silicon** | The player ships D3D11 only (`-force-glcore`/`-force-vulkan` "not built"; `-force-d3d12` needs vkd3d, which the gcenx wine lacks). wined3d D3D11 fails at FL 9.3 (Apple GL 4.1 cap; a GL-capability `dlsym`-shim is bypassed by Wine's internal GL dispatch). DXVK-macOS 1.10.3 DOES work for many titles (see tested table) but spams non-fatal `VK_ERROR_OUT_OF_POOL_MEMORY` warnings on heavy scenes — suppress with `MVK_CONFIG_LOG_LEVEL=error`, do not mistake the spam for a freeze. Truly stuck only if DXVK itself cannot bring up the device. **Check Steam/GOG for a native macOS build first.** |
| **GameMaker via wined3d or D3DMetal** | wined3d gives 100% black screen + audio (7 registry combos tried, all failed). D3DMetal crashes on `CheckMultisampleQualityLevels` `0x80070057`. Only DXVK-macOS async 1.10.3 works. |
| **D3D12** | The bundled gcenx Wine has no vkd3d-proton, so D3D12 is unusable. Unity 6 additionally enforces D3D12 Feature Level 12.1. |
| **Stock DXVK 2.x / 3.x on Apple GPUs** | Hard-requires Vulkan 1.3 + geometry/tessellation shaders. MoltenVK exposes neither. Device init aborts. |
| **Online co-op / achievements under Wine** | Needs a reachable Steam client, which a macOS Wine prefix cannot provide. Single-player is fine; multiplayer is not. |
| **Native rebuild of Unity / GameMaker** | Impossible without the original project. There is no open engine to host those assets on macOS — unlike Godot. |

---

## Render verification

"It launched" is not "it renders". A black screen, a frozen frame and a bright error
dialog all look fine in a thumbnail, so the gate has to be numeric. The skill ships the
tooling in [`tools_render/`](tools_render/):

```bash
zsh tools_render/render_gate.sh "/Applications/Game.app" --wait 45
```

The script **probes Screen Recording permission exactly once** and then commits to one
path — this is deliberate, because retrying `screencapture` in different guises is the
single biggest time sink in this workflow:

| | Path A — permission granted | Path B — permission denied |
| --- | --- | --- |
| Evidence | two captures 6 s apart | window geometry, DXVK state-cache regrowth, per-frame log warning rate |
| Gates | `dark_fraction < 0.95`, `color_buckets > 12`, motion diff > 0.001 | cache rebuilt from 0 bytes, warning rate ≈ FPS, no `err:` in DXVK logs |
| Verdict | PASS / FAIL | PASS / FAIL / INCONCLUSIVE (ask the user) |

Requires Pillow for Path A (`python3 -m pip install pillow`); the script hunts for an
interpreter that has it and degrades to Path B-style INCONCLUSIVE if none is found.

## Memory-leak verification & dxvk.conf

"It runs at 60 FPS" is not "it stays at 60 FPS". Unity URP games under
DXVK + MoltenVK have a known pathology: per-frame dynamic-resource allocation
exhausts Vulkan descriptor pools, MoltenVK never recycles the dynamically
allocated descriptors, and `phys_footprint` grows **even while idle at the menu**
(~56 MB/min measured) until macOS starts compressing/swapping — the classic
"gets laggier the longer I play" report.

Diagnose with `footprint` (works even when `ps`/`top` are permission-denied):

```bash
PID=$(pgrep -f "Game.exe" | head -1)
footprint --noCategories -f formatted "$PID"   # phys_footprint — sample twice, 3-4 min apart
footprint -f formatted "$PID"                  # per-category breakdown — attributes the growth
```

Category deltas attribute the leak: growing `IOAccelerator`/`graphics` buckets =
DXVK↔MoltenVK churn (fixable); growing `WINE_RESERVE`/`VM_ALLOCATE` = Unity native
heap (game side). Fix the port-layer leak with a `dxvk.conf` next to the game exe:

```
d3d11.cachedDynamicResources = "a"   # stop per-frame dynamic reallocation
dxgi.maxFrameLatency = 1             # bounds live descriptor sets
dxvk.numCompilerThreads = 4
```

Measured on a Unity 6 URP title: **56 MB/min → 1.4 MB/min (~40x) at menu idle**;
graphics categories flat. Verify option support first with
`strings system32/d3d11.dll | grep -i cachedDynamic`.

---

## Caveats

Condensed rules. `SKILL.md` §14 keeps the full dated, evidence-backed log — read it
before attempting an unfamiliar engine.

**Assets**
- Copy dotfiles explicitly: `cp -R "src/." "dst/"`. Shell globs skip `.godot/` and that
  kills the port.
- Never let the desktop editor touch the project before you have a pristine copy of
  `.godot/` from the original archive.

**Signing**
- Always `codesign --force --deep --sign -` as the **last** step, after every edit.
- A copied Godot binary SIGKILLs with exit 137 and no output if left unsigned —
  AMFI kills it before any banner prints.
- **Do not** ad-hoc sign Wine bundles. The Steam emulator writes inside the bundle at
  runtime and breaks the seal, so Gatekeeper reports the app as damaged. Use
  `xattr -dr com.apple.quarantine` and have the user approve once via
  System Settings → Privacy & Security → Open Anyway.

**Extensions and autoloads**
- Disabling a `.gdextension` takes three steps, not one: rename the file, remove the
  `[editor_plugins]` line that force-enables it, and delete the stale
  `.godot/**/extension_list.cfg` entry.
- Delete dead autoloads. Dev-only tooling (e.g. MCP addons) is listed as autoloads but
  its `.gd` files are not exported, which yields "Failed to instantiate autoload".
- OnlineFix repacks: force `WINEDLLOVERRIDES="winmm=b"` so the proxy never loads, and
  replace the real `steam_api64.dll` with an offline emulator (GoldBerg). Skip either and
  the game dies after 30–60s with no `Player.log` at all.

**Graphics backends on Apple Silicon**
- GameMaker → DXVK-macOS async 1.10.3 only. Copy just `d3d11.dll` + `d3d10core.dll`,
  keep Wine's builtin `dxgi`, set `WINEDLLOVERRIDES="d3d11=n,b"` (not `d3d11,dxgi=n,b`),
  and `DXVK_ASYNC=1`.
- Unity 6 Mono → DXVK 1.10.3, `-force-d3d11`. No GL shim.
- Unity 2022.3 Mono → wined3d plus a `DYLD_INSERT_LIBRARIES` shim that fakes
  `GL_EXT_shader_integer_mix` and `GL_ARB_polygon_offset_clamp`.
- Verify the downloaded DXVK tarball with `tar -tzf`. Behind a proxy the direct GitHub
  URL can silently return a truncated ~2.7 MB file.

**Verification**
- `--quit-after <sec>` is the only reliable timeout on macOS — `timeout` is not installed.
  A heavy engine can also be SIGKILLed (137) inside a tool sandbox; re-run with the
  sandbox disabled.
- `Player.log` is the fastest go/no-go for Unity:
  `<prefix>/drive_c/users/<user>/AppData/LocalLow/<Company>/<Product>/Player.log`.
  No log after 60s means the game died before or inside engine init.
- Launch test apps with `open -a "/Applications/X.app"`, never `nohup ... &` —
  LaunchServices detaches the process so it survives between tool calls.
- Judge rendering numerically, not visually — use
  [`tools_render/render_gate.sh`](tools_render/render_gate.sh) (see
  [Render verification](#render-verification)). It probes Screen Recording **once**;
  if it is denied, do not retry `screencapture` in another guise, take Path B.
- A bright error dialog also scores as "rendering", so always cross-check window size
  (`280x143` = D3D failure dialog) and log contents.

**Video / Media Foundation**
- Wine cannot decode video: `winedmo.so` wants x86_64 FFmpeg 7 dylibs that no gcenx
  bundle ships. A Unity logo/cinematic video therefore **hangs the game on a black
  screen** that is indistinguishable from a broken renderer. Move the `.mp4` files out
  of `<Game>_Data/StreamingAssets/video/` — Unity logs "video ... dont found" and
  carries on. Trade-off: no cinematics.

**Steam repack emulators**
- `SOVEREIGN` (`SOVEREIGN64.dll` + `SOVEREIGN.ini` + `steam_api64.svrn`) is fully offline
  and needs no extra work. Switch UI language by editing `Language=` in `SOVEREIGN.ini`
  **and** setting the launcher's `LANG`/`LC_ALL` — they must agree.
- GoldBerg (`steam_settings/`) and TENOKE (`tenoke.ini`) are offline too. OnlineFix
  (`winmm.dll` + `OnlineFix64.dll`, no `steam_settings/`) is not — see above.

**Misc**
- Wine prefix init needs `wineboot -u`; `wine cmd` will not create `drive_c`.
- Use `bsdtar` for RAR — there is no `unrar`. **Do not use `7z`/p7zip 17.05**: it lists
  RAR5 archives fine but `7z x` reports `Unsupported Method` and writes 0-byte files.
- Background extraction/wine must run through the tool's own background mechanism;
  `nohup ... &` is killed as soon as the tool call returns.
- Never put a `:` in the `.app` or launcher name — LaunchServices treats it as a path
  separator and `open` reports "its executable is missing". Use `-`.
- `iconutil` chokes on some PNGs. Generate `.icns` with Pillow instead.
- Reuse a Wine bundle via `cp -Rc` (APFS clone) — instant, and the copy is independent.
- Set `LANG`/`LC_ALL` and add Wine font replacements for CJK in **Godot** Windows builds.
  GameMaker and Unity games ship their own fonts and need none of this.

---

## Contributing

The pitfalls log in `SKILL.md` §14 is append-only and is the most valuable part of this
repo. If a port fails in a new way, or you find a fix, add a dated entry with what
broke, what fixed it, and how you verified it. Pull requests welcome.

## License

MIT.
