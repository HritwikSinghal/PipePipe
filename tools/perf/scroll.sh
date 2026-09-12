#!/usr/bin/env bash
# Scroll-jank measurement for PipePipeD.
#
#   tools/perf/scroll.sh [label]
#
# Env knobs:
#   SCROLL_TARGET   extra `am start` args to land on the screen under test.
#                   Default: the launcher activity. Override to measure a specific list, e.g.
#                     SCROLL_TARGET='-n wtf.pipepiped.debug/.local.playlist.LocalPlaylistFragment'
#                   (see docs/perf-automation-plan.md for the seeded-playlist workload).
#   SWIPE_PAIRS     down+up swipe pairs to perform      (default 12)
#   SWIPE_MS        duration of one swipe gesture, ms   (default 300)
#   SETTLE_SEC      after launch, before measuring      (default 6)
#   ANDROID_SERIAL                                       (default emulator-5554)
#
# HOW IT SAMPLES, and the caveat that comes with it:
#   `dumpsys gfxinfo <pkg> framestats` exposes only the LAST 120 FRAMES. At 60Hz that is two
#   seconds, so this polls between gestures and concatenates. The device does not deduplicate,
#   so blocks overlap; framestats.py dedupes on IntendedVsync.
#   Polling itself costs a binder round trip during the measured window. That overhead is in
#   every arm equally, so A/B deltas remain meaningful, but ABSOLUTE jank here is mildly
#   pessimistic. Perfetto/Macrobenchmark avoids this and is the Phase 4 answer.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LABEL="${1:-scroll}"
SWIPE_PAIRS="${SWIPE_PAIRS:-12}"
SWIPE_MS="${SWIPE_MS:-300}"
SETTLE_SEC="${SETTLE_SEC:-6}"
SCROLL_TARGET="${SCROLL_TARGET:-}"

# Which build variant to measure. Default "benchmark": the debug variant is
# DEBUGGABLE, so ART refuses to AOT-compile it and its compilation state can be
# neither pinned nor truthfully recorded -- measuring it produces a number that
# cannot be compared to anything. Override with VARIANT=debug deliberately.
VARIANT="${VARIANT:-benchmark}"

perf_require_device
APP_ID="$(perf_app_id "$VARIANT")"
perf_assert_quiet_device || true

# Screen geometry, read from the device rather than assumed -- a different AVD skin would
# otherwise send every swipe to the wrong place and silently measure an idle screen.
SIZE="$(perf_adb shell wm size | tr -d '\r' | awk -F': *' '/Physical size/{print $2}')"
SCREEN_W="${SIZE%x*}"
SCREEN_H="${SIZE#*x}"
[ -n "$SCREEN_W" ] && [ -n "$SCREEN_H" ] || perf_die "could not read screen size from 'wm size'"
MID_X=$(( SCREEN_W / 2 ))
LOW_Y=$(( SCREEN_H * 75 / 100 ))
HIGH_Y=$(( SCREEN_H * 25 / 100 ))

RUN_DIR="$(perf_new_run_dir "$LABEL")"
RAW="$RUN_DIR/framestats-raw.txt"
SUMMARY="$RUN_DIR/summary.json"
: > "$RAW"

perf_log "app:     $APP_ID"
perf_log "screen:  ${SCREEN_W}x${SCREEN_H}  swipe x=$MID_X  $LOW_Y <-> $HIGH_Y"
perf_log "gesture: $SWIPE_PAIRS down+up pairs at ${SWIPE_MS}ms"
perf_log "output:  $RUN_DIR"

perf_kill_and_settle "$APP_ID"
# shellcheck disable=SC2086  # SCROLL_TARGET is deliberately word-split into am start args
if [ -n "$SCROLL_TARGET" ]; then
  perf_adb shell am start -W -S $SCROLL_TARGET >/dev/null
else
  ACTIVITY="$(perf_launchable_activity "$APP_ID")"
  perf_adb shell am start -W -S -n "$ACTIVITY" >/dev/null
fi

perf_log "settling ${SETTLE_SEC}s"
sleep "$SETTLE_SEC"

# Confirm the app is actually foreground before measuring. Measuring a screen that never
# appeared yields a clean-looking 0% jank over ~no frames, which is the worst kind of wrong.
TOP="$(perf_adb shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | tr -d '\r' || true)"
case "$TOP" in
  *"$APP_ID"*) : ;;
  *) perf_die "app is not foreground after launch; top was: ${TOP:-<none>}" ;;
esac

collect() { perf_adb shell dumpsys gfxinfo "$APP_ID" framestats 2>/dev/null >> "$RAW" || true; }

perf_adb shell dumpsys gfxinfo "$APP_ID" reset >/dev/null 2>&1 || true

for (( p = 1; p <= SWIPE_PAIRS; p++ )); do
  perf_adb shell input swipe "$MID_X" "$LOW_Y"  "$MID_X" "$HIGH_Y" "$SWIPE_MS"
  collect
  perf_adb shell input swipe "$MID_X" "$HIGH_Y" "$MID_X" "$LOW_Y"  "$SWIPE_MS"
  collect
  printf '  pair %2d/%-2d\n' "$p" "$SWIPE_PAIRS" >&2
done
collect

perf_adb shell am force-stop "$APP_ID"

METRICS="$(python3 "$(dirname "${BASH_SOURCE[0]}")/framestats.py" --json "$RAW")" \
  || perf_die "framestats parsing failed -- see $RAW"

jq -nc \
  --arg label "$LABEL" \
  --argjson context "$(perf_context_json "$APP_ID")" \
  --arg scrollTarget "${SCROLL_TARGET:-<launcher>}" \
  --argjson swipePairs "$SWIPE_PAIRS" \
  --argjson swipeMs "$SWIPE_MS" \
  --arg screen "${SCREEN_W}x${SCREEN_H}" \
  --argjson metrics "$METRICS" \
  '{label:$label, metric:"gfxinfo_framestats", scrollTarget:$scrollTarget,
    swipePairs:$swipePairs, swipeMs:$swipeMs, screen:$screen,
    context:$context, metrics:$metrics}' \
  | tee "$SUMMARY" | jq .

echo >&2
perf_log "raw:     $RAW"
perf_log "summary: $SUMMARY"
