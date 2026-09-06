#!/bin/zsh
# Unified Wine launcher template for game-to-mac ports.
#
# TWO MODES, decided automatically at launch (no CLI flag needed):
#   library  (default) — shares ONE Wine runtime + DXVK cache from
#       ~/Library/Application Support/GameToMac/{runtimes,dxvk,prefixes}
#   portable (fallback) — if that shared location is absent (the .app was
#       copied to a Mac without GameToMac), falls back to the in-bundle
#       Contents/Resources/{wine,prefix,dxvk}. The .app then runs standalone.
#
# To use: copy this file to Contents/MacOS/<launcher>, make it executable,
# name CFBundleExecutable to match, and edit ONLY the PER-GAME PINS block.
# Nothing else needs to change for a standard Unity/GameMaker Wine port.

set -u
setopt NULL_GLOB   # zsh aborts on an unmatched glob; Player.log dir may not exist yet

# ============================ PER-GAME PINS ============================
GAME_ID="example-game"              # used for the per-user config + manifest file name
GAME_NAME="Example Game"
EXE_NAME="Game.exe"
COMPANY="Company"                   # from <Game>_Data/app.info (Unity) — for Player.log path
PRODUCT="Game"                      # from <Game>_Data/app.info (Unity)
WINE_RUNTIME="gcenx-wine-11.16"     # must match GameToMac/runtimes/<dir>
DXVK_VER="1.10.3"                   # must match GameToMac/dxvk/<dir>
PREFIX_NAME="example-game"          # must match GameToMac/prefixes/<dir>
DEFAULT_LANG="english"              # schinese|english|japanese|german|french|russian|portuguese
FORCE_RENDERER="-force-d3d11"
# =======================================================================

SELF="$0"
MACOS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RES="$(cd "$MACOS_DIR/../Resources" && pwd)"
GT="$HOME/Library/Application Support/GameToMac"

# ---- Resolve Wine runtime: library first, portable fallback ----
RUNTIME_INT="$RES/wine"
if [ -x "$GT/runtimes/$WINE_RUNTIME/bin/wine" ]; then
  RUNTIME="$GT/runtimes/$WINE_RUNTIME"; MODE="library"
elif [ -x "$RUNTIME_INT/bin/wine" ]; then
  RUNTIME="$RUNTIME_INT"; MODE="portable"
else
  osascript -e "display alert \"$GAME_NAME\" message \"No Wine runtime found.\n\nLooked in:\n  $GT/runtimes/$WINE_RUNTIME\n  $RUNTIME_INT\" as critical" 2>/dev/null
  exit 1
fi
WINE="$RUNTIME/bin/wine"
WINE_LIB="$RUNTIME/lib"
ICD="$RUNTIME/lib/wine/x86_64-unix/vulkan/icd.d/MoltenVK_icd.json"

# ---- Resolve prefix: external (library) or internal (portable) ----
if [ "$MODE" = "library" ]; then PREFIX="$GT/prefixes/$PREFIX_NAME"
else PREFIX="$RES/prefix"; fi

# ---- Wine + Vulkan (MoltenVK) runtime ----
export WINEPREFIX="$PREFIX"
export DYLD_FALLBACK_LIBRARY_PATH="$WINE_LIB${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export VK_ICD_FILENAMES="$ICD"
export WINEDEBUG="${WINEDEBUG:--all}"

# ---- Per-user overrides (edit to iterate without touching this launcher) ----
CFG="$HOME/Library/Application Support/$GAME_ID/config.sh"
[ -f "$CFG" ] && . "$CFG"

export DXVK_ASYNC="${DXVK_ASYNC:-1}"
export MVK_CONFIG_FAST_MATH_ENABLED=1
export DXVK_FRAME_RATE="${DXVK_FRAME_RATE:-60}"
export MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-error}"
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-error}"
DXVK_LOG_PATH="$RES/dxvk-logs"
[ "$MODE" = "library" ] && DXVK_LOG_PATH="$GT/dxvk-logs/$GAME_ID"
export DXVK_LOG_PATH
mkdir -p "$DXVK_LOG_PATH"

# ---- Language ----
export GAME_LANG="${GAME_LANG:-$DEFAULT_LANG}"
case "$GAME_LANG" in
  schinese|Simplified*) LANG_CODE=zh_CN.UTF-8 ;;
  japanese)             LANG_CODE=ja_JP.UTF-8 ;;
  german)               LANG_CODE=de_DE.UTF-8 ;;
  french)               LANG_CODE=fr_FR.UTF-8 ;;
  russian)              LANG_CODE=ru_RU.UTF-8 ;;
  portuguese*)          LANG_CODE=pt_BR.UTF-8 ;;
  *)                    LANG_CODE=en_US.UTF-8 ;;
esac
export LANG="${LANG:-$LANG_CODE}"
export LC_ALL="${LC_ALL:-$LANG_CODE}"

# ---- DLL overrides ----
# d3d11/dxgi come from DXVK (native DLLs injected into the prefix system32).
# winmm stays Wine BUILTIN unless USE_ONLINEFIX=1 (OnlineFix repacks need a
# reachable Steam client and kill the game otherwise).
export USE_ONLINEFIX="${USE_ONLINEFIX:-0}"
if [ "$USE_ONLINEFIX" = "1" ]; then
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d11=n,b;dxgi=n,b;winmm=n,b}"
else
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d11=n,b;dxgi=n,b;winmm=b}"
fi

# ---- First run: ensure prefix exists, inject DXVK into its system32 ----
if [ ! -f "$PREFIX/system.reg" ]; then
  mkdir -p "$PREFIX"
  "$WINE" wineboot --init >/dev/null 2>&1 || true
fi
for d in d3d11 d3d10core; do
  if [ ! -f "$PREFIX/drive_c/windows/system32/$d.dll" ]; then
    for src in "$GT/dxvk/$DXVK_VER/x64/$d.dll" "$RES/dxvk/x64/$d.dll"; do
      [ -f "$src" ] && { cp "$src" "$PREFIX/drive_c/windows/system32/$d.dll"; break; }
    done
  fi
done

# ---- Truncate Unity Player.log so it never accumulates ----
for D in "$PREFIX"/drive_c/users/*/AppData/LocalLow/$COMPANY/$PRODUCT/; do
  [ -d "$D" ] || continue
  : > "$D/Player.log"
done

EXE="$RES/game/$EXE_NAME"
if [ ! -f "$EXE" ]; then
  osascript -e "display alert \"$GAME_NAME\" message \"Game executable not found inside the app bundle:\n$EXE\" as critical" 2>/dev/null
  exit 1
fi

cd "$RES/game"
export RENDERER="${RENDERER:-$FORCE_RENDERER}"
export EXTRA_FLAGS="${EXTRA_FLAGS-}"

WINELOG="${WINELOG:-$RES/wine.log}"
echo "[game-to-mac] mode=$MODE runtime=$RUNTIME prefix=$PREFIX" >> "$WINELOG"
exec "$WINE" "$EXE" $RENDERER $EXTRA_FLAGS "$@" >> "$WINELOG" 2>&1
