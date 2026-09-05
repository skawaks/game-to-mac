#!/bin/zsh
#
# render_gate.sh — objective render verification for a Wine-wrapped macOS .app.
#
#   zsh render_gate.sh "/Applications/My Fire Is Bigger Than Yours.app" [--wait 45]
#
# Why this exists
# ---------------
# The agent process often has NO Screen Recording permission, so `screencapture`
# fails with "could not create image from display". Repeatedly retrying it in
# different guises (osascript, macshot, another app) burns 5-6 tool calls and
# proves nothing.
#
# So: probe the permission EXACTLY ONCE. Pass -> Path A (pixel evidence).
# Fail -> silently switch to Path B (permission-free gates) and never touch
# screencapture again this run.
#
# Path A  pixels     : two captures 6s apart -> black-screen + motion check.
# Path B  no pixels  : window geometry + DXVK state-cache growth + per-frame
#                      Unity log warning rate (= a free FPS meter).
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = INCONCLUSIVE (ask the user to look).

set -u
setopt NULL_GLOB 2>/dev/null || true   # zsh aborts on an unmatched glob otherwise

APP="${1:-}"
WAIT=45
while (( $# )); do
  case "$1" in
    --wait) WAIT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: render_gate.sh \"/Applications/Game.app\" [--wait 45]"
  exit 2
fi

TOOLS="$(cd "$(dirname "$0")" && pwd)"
RES="$APP/Contents/Resources"
NAME="$(basename "$APP" .app)"
TMP="$(mktemp -d)"
FAIL=0
INCONCLUSIVE=0

# ---------------------------------------------------------------- winlist ---
WINLIST="$TMP/winlist"
if ! cc -o "$WINLIST" "$TOOLS/winlist.c" \
      -framework CoreGraphics -framework CoreFoundation 2>/dev/null; then
  echo "!! could not build winlist.c — no window evidence available"
  WINLIST=""
fi

# ------------------------------------------------------- locate the log -----
# A Wine-wrapped .app built to this playbook keeps its prefix INSIDE the bundle
# ($RES/prefix). Older ports put it under ~/Library/Application Support.
PREFIX_DIR=""
for cand in "$RES/prefix" "$HOME/Library/Application Support"/*/prefix; do
  [ -d "$cand" ] && PREFIX_DIR="$cand" && break
done

PLAYER_LOG=""
if [ -n "$PREFIX_DIR" ]; then
  # Prefer the log whose parent directory matches the app name. A prefix cloned
  # from a sibling port carries that game's leftovers (e.g. <Other Studio>/
  # <Other Game>/Player.log), and the wrong pick silently reports 0 FPS.
  for cand in "$PREFIX_DIR"/drive_c/users/*/AppData/LocalLow/*/*/Player.log; do
    [ -f "$cand" ] || continue
    if [ "$(basename "$(dirname "$cand")")" = "$NAME" ]; then
      PLAYER_LOG="$cand"
      break
    fi
  done
  # Fallback: newest log in the prefix.
  if [ -z "$PLAYER_LOG" ]; then
    PLAYER_LOG="$(ls -t "$PREFIX_DIR"/drive_c/users/*/AppData/LocalLow/*/*/Player.log 2>/dev/null | head -1)"
  fi
  if [ -n "$PLAYER_LOG" ] && [ -n "$WINLIST" ]; then
    AGE=$(( $(date +%s) - $(stat -f%m "$PLAYER_LOG") ))
    if (( AGE > 600 )); then
      echo "!! WARNING: selected Player.log is ${AGE}s old — it may belong to another port"
    fi
  fi
fi

# ---------------------------------------------------------- launch (cold) ---
# Cold start matters: clearing the DXVK cache only proves something if we then
# watch it get rebuilt from empty.
if [ -n "$WINLIST" ] && "$WINLIST" 2>/dev/null | grep -qF "$NAME"; then
  COLD=0
else
  COLD=1
  CACHES=()
  if [ -d "$RES/game" ]; then
    for c in "$RES"/game/*.dxvk-cache; do
      [ -f "$c" ] && CACHES+=("$c")
    done
  fi
  if (( ${#CACHES[@]} )); then
    echo "-- clearing ${#CACHES[@]} DXVK state cache(s) for a cold start"
    rm -f "${CACHES[@]}"
  fi
  echo "-- launching $NAME (waiting ${WAIT}s)"
  open -a "$APP"
  sleep "$WAIT"
fi

# ------------------------------------------------------- window geometry ----
WID=""; GEOM=""
if [ -n "$WINLIST" ]; then
  ROW="$("$WINLIST" 2>/dev/null | grep -F "$NAME" | head -1)"
  if [ -n "$ROW" ]; then
    WID="$(printf '%s' "$ROW" | cut -f1)"
    GEOM="$(printf '%s' "$ROW" | cut -f3)"
    echo "-- window: id=$WID geometry=$GEOM"
    # 280x143 is the D3D 'CheckMultisampleQualityLevels' error dialog — the
    # single most common false positive: it is bright, so pixel stats alone
    # would score it as "rendering".
    if [ "$GEOM" = "280x143" ]; then
      echo "!! ERROR DIALOG (280x143), not the game window"
      FAIL=1
    fi
  else
    echo "!! no window titled '$NAME' — game likely died during init"
    FAIL=1
  fi
fi

# ============================================================================
# Probe Screen Recording permission ONCE. No retries. No alternative tools.
# ============================================================================
PERM=0
if [ -n "$WID" ]; then
  if screencapture -x -l "$WID" "$TMP/probe.png" 2>/dev/null \
     && [ -s "$TMP/probe.png" ]; then
    PERM=1
  fi
fi

if (( PERM )); then
  # ------------------------------------------------- Path A: pixel evidence --
  echo "-- Screen Recording: GRANTED -> Path A (pixel evidence)"
  # Pillow is not in the system python; hunt for any interpreter that has it.
  PY=""
  for p in python3 \
           "$HOME/.workbuddy/binaries/python/envs/default/bin/python" \
           /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$p" ] && "$p" -c "import PIL" >/dev/null 2>&1; then
      PY="$p"
      break
    fi
  done
  if [ -z "$PY" ]; then
    echo "!! no Python with Pillow found — path A cannot score pixels."
    echo "   fix:  python3 -m pip install pillow"
    INCONCLUSIVE=1
  fi
  screencapture -x -l "$WID" "$TMP/a.png" 2>/dev/null
  sleep 6
  screencapture -x -l "$WID" "$TMP/b.png" 2>/dev/null
  if [ -n "$PY" ] && [ -s "$TMP/a.png" ] && [ -s "$TMP/b.png" ]; then
    "$PY" "$TOOLS/analyze_png.py" "$TMP/a.png" "$TMP/b.png" || FAIL=1
    cp "$TMP/a.png" "$TMP/frame_a.png"
    echo "   frames kept at: $TMP/frame_a.png"
  elif [ -n "$PY" ]; then
    echo "!! capture produced no file"
    INCONCLUSIVE=1
  fi
else
  # ---------------------------------------- Path B: permission-free gates --
  echo "-- Screen Recording: DENIED -> Path B (permission-free gates)"
  echo "   (do NOT retry screencapture; it will not start working)"

  # Gate 1 — DXVK state cache regenerated from empty.
  # DXVK only appends an entry when it compiles a graphics/compute pipeline,
  # which only happens when the game issues real draw calls.
  if (( COLD )); then
    CACHE=""
    for c in "$RES"/game/*.dxvk-cache; do
      [ -f "$c" ] && CACHE="$c"
    done
    if [ -n "$CACHE" ]; then
      S1=$(stat -f%z "$CACHE")
      echo "-- gate 1a: DXVK cache rebuilt from 0 -> ${S1} bytes"
      sleep 30
      S2=$(stat -f%z "$CACHE" 2>/dev/null || echo 0)
      echo "-- gate 1b: 30s later -> ${S2} bytes"
      if (( S2 > S1 )); then
        echo "   PASS: still growing = new pipelines compiling = real draw calls"
      elif (( S1 > 0 )); then
        echo "   PASS: rebuilt from 0 to ${S1} bytes; stable = shader set complete"
      else
        echo "   FAIL: DXVK cache did not regenerate"
        FAIL=1
      fi
    else
      echo "-- gate 1: no *.dxvk-cache written — engine may not be D3D9/11 via DXVK"
      INCONCLUSIVE=1
    fi
  else
    echo "-- gate 1: SKIPPED (game was already running; needs a cold start)"
    INCONCLUSIVE=1
  fi

  # Gate 2 — per-frame log warning rate = FPS meter.
  # Take the most repeated line in the tail of Player.log, count it twice 10s
  # apart. Unity's URP spits exactly one warning per frame, so this reads as Hz.
  if [ -n "$PLAYER_LOG" ] && [ -f "$PLAYER_LOG" ]; then
    echo "-- gate 2: Player.log = $PLAYER_LOG"
    LINE=$(tail -500 "$PLAYER_LOG" | sort | uniq -c | sort -rn | head -1 \
           | sed 's/^ *[0-9]* //')
    C1=$(grep -F -c -- "$LINE" "$PLAYER_LOG" 2>/dev/null || echo 0)
    sleep 10
    C2=$(grep -F -c -- "$LINE" "$PLAYER_LOG" 2>/dev/null || echo 0)
    RATE=$(( (C2 - C1) / 10 ))
    echo "   repeating line: \"$(printf '%s' "$LINE" | cut -c1-70)...\""
    if (( RATE > 5 )); then
      echo "   PASS: ~${RATE} log events/sec => render loop running at ~${RATE} FPS"
    else
      echo "   INCONCLUSIVE: only ${RATE} events/sec (log may be idle, not broken)"
      INCONCLUSIVE=1
    fi
    echo "-- gate 3: DXVK errors"
    ERRCOUNT=0
    for f in "$RES"/dxvk-logs/*.log; do
      n=$(grep -c "^err:" "$f" 2>/dev/null || echo 0)
      ERRCOUNT=$(( ERRCOUNT + ${n:-0} ))
    done
    echo "   ${ERRCOUNT} 'err:' lines in dxvk-logs (non-zero means real DXVK failures)"
  else
    echo "-- gate 2/3: no Player.log found — check <prefix>/drive_c/users/<u>/AppData/LocalLow/<Company>/<Game>/"
    INCONCLUSIVE=1
  fi
fi

# ------------------------------------------------------------------ verdict --
echo
if (( FAIL )); then
  echo "RESULT: FAIL"
  exit 1
elif (( INCONCLUSIVE )); then
  echo "RESULT: INCONCLUSIVE — evidence is partial; ask the user to confirm visually."
  echo "        (Grant Screen Recording to the agent app for automated pixel checks.)"
  exit 2
else
  echo "RESULT: PASS"
  exit 0
fi
