#!/usr/bin/env bash
# Cold-start baseline for PipePipeD.
#
#   tools/perf/coldstart.sh [label]
#
# Env knobs:
#   ITERATIONS    measured iterations              (default 15; must be >= 1)
#   WARMUPS       discarded leading iterations     (default 3)
#   COMPILE_MODE  cmd package compile -m <mode>    (default speed; "skip" to leave as-is)
#   SETTLE_SEC    sleep between force-stop and start (default 2)
#   ANDROID_SERIAL                                  (default emulator-5554)
#   PERF_ALLOW_NOISY            proceed despite animations not being fully disabled (default: die)
#   PERF_ALLOW_COMPILE_MISMATCH proceed despite the compile pin not taking (default: die)
#
# WHAT THIS MEASURES, and what it does not:
#   `am start -W` TotalTime is the time from system_server receiving the intent to the
#   activity finishing its FIRST DRAW. It is not time-to-usable-content -- for this app the
#   first frame is a mostly-empty tab pager, and the tab's content arrives later over the
#   network. Treat it as a coarse regression signal, not as "how long until the app is ready".
#   The honest version of that number needs reportFullyDrawn() in the app (see
#   docs/perf-automation-plan.md, Phase 3).
#
# Cold means PROCESS-cold (am force-stop), deliberately not `pm clear`:
#   clearing app data brings back the one-time first-run dialogs ("Announcement" and the
#   update-checker prompt), so only some iterations would pay for them and the median would
#   be measuring dialog dismissal, not startup.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LABEL="${1:-coldstart}"
ITERATIONS="${ITERATIONS:-15}"
WARMUPS="${WARMUPS:-3}"
COMPILE_MODE="${COMPILE_MODE:-speed}"
SETTLE_SEC="${SETTLE_SEC:-2}"
MAX_LAUNCH_ATTEMPTS=4

# ITERATIONS=0 would otherwise run the loop zero times and exit 0 with a summary reading
# "n":0 -- a silently empty result that looks like a completed measurement.
[ "$ITERATIONS" -ge 1 ] 2>/dev/null || perf_die "ITERATIONS must be >= 1 (got '$ITERATIONS')"

# Which build variant to measure. Default "benchmark": the debug variant is
# DEBUGGABLE, so ART refuses to AOT-compile it and its compilation state can be
# neither pinned nor truthfully recorded -- measuring it produces a number that
# cannot be compared to anything. Override with VARIANT=debug deliberately.
VARIANT="${VARIANT:-benchmark}"

perf_require_device
APP_ID="$(perf_app_id "$VARIANT")"
ACTIVITY="$(perf_launchable_activity "$APP_ID")"
[ -n "$ACTIVITY" ] || perf_die "could not resolve a launchable activity for $APP_ID"

# Capture the actual scale values + a quiet boolean instead of discarding them: a noisy
# device inflates every timing in this run, so it is fatal by default. The same reading is
# threaded into the summary's context (below) so the recorded state matches what was
# enforced, rather than re-querying a device whose state could have moved on since.
QUIET_JSON="$(perf_assert_quiet_device)" || true
if [ "$(printf '%s' "$QUIET_JSON" | jq -r '.quiet')" != "true" ]; then
  if [ -n "${PERF_ALLOW_NOISY:-}" ]; then
    perf_log "warning: proceeding on a noisy device (PERF_ALLOW_NOISY=1): $QUIET_JSON"
  else
    perf_die "device animations are not fully disabled: $QUIET_JSON" \
      "(set PERF_ALLOW_NOISY=1 to proceed anyway and record the noisy state)"
  fi
fi

RUN_DIR="$(perf_new_run_dir "$LABEL")"
RAW="$RUN_DIR/raw.jsonl"
SUMMARY="$RUN_DIR/summary.json"
: > "$RAW"

perf_log "app:        $APP_ID"
perf_log "activity:   $ACTIVITY"
perf_log "iterations: $WARMUPS warmup + $ITERATIONS measured"
perf_log "output:     $RUN_DIR"

[ "$COMPILE_MODE" = "skip" ] || perf_pin_compilation "$APP_ID" "$COMPILE_MODE"

total=$(( WARMUPS + ITERATIONS ))
for (( i = 1; i <= total; i++ )); do
  warmup=false
  [ "$i" -le "$WARMUPS" ] && warmup=true

  # A warm launch among cold ones is a different workload -- never average them together.
  # `am start -S` force-stops as part of the start, which closes the race where background
  # work (WorkManager / the player service) respawns the process between a separate
  # force-stop and the launch. perf_kill_and_settle first is belt-and-braces.
  #
  # A discarded retry (LaunchState != COLD) still did a full launch and warmed page/ART
  # caches before the attempt that gets kept -- if one arm needs many retries and the other
  # needs none, that is a systematic difference between the arms. `attempt` (left at its
  # final value once the loop breaks) is recorded below so that difference is visible instead
  # of silently disappearing once only the kept attempt's numbers are written out.
  status=""; launch_state=""; this_time=""; total_time=""; wait_time=""
  for (( attempt = 1; attempt <= MAX_LAUNCH_ATTEMPTS; attempt++ )); do
    perf_kill_and_settle "$APP_ID"
    sleep "$SETTLE_SEC"

    out="$(perf_adb shell am start -W -S -n "$ACTIVITY" 2>/dev/null | tr -d '\r')"
    status="$(printf '%s\n' "$out"      | awk -F': *' '/^Status/{print $2}')"
    launch_state="$(printf '%s\n' "$out"| awk -F': *' '/^LaunchState/{print $2}')"
    this_time="$(printf '%s\n' "$out"   | awk -F': *' '/^ThisTime/{print $2}')"
    total_time="$(printf '%s\n' "$out"  | awk -F': *' '/^TotalTime/{print $2}')"
    wait_time="$(printf '%s\n' "$out"   | awk -F': *' '/^WaitTime/{print $2}')"

    [ "$status" = "ok" ]  || perf_die "iteration $i attempt $attempt: am start reported status '$status'"
    [ -n "$total_time" ]  || perf_die "iteration $i attempt $attempt: no TotalTime in am start output"
    [ -n "$wait_time" ]   || perf_die "iteration $i attempt $attempt: no WaitTime in am start output"
    # ThisTime is confirmed ABSENT from `am start -W` on this rig's platform (Android 16 /
    # SDK36) for every app, not just this one -- it is not a parse failure, so this does not
    # perf_die. It is recorded as JSON null below rather than defaulted to 0, which would
    # read as a real (and impossible) zero-duration measurement instead of "not reported here".

    [ -z "$launch_state" ] && break
    [ "$launch_state" = "COLD" ] && break
    if [ "$attempt" -eq "$MAX_LAUNCH_ATTEMPTS" ]; then
      perf_die "iteration $i: never achieved a COLD launch in $MAX_LAUNCH_ATTEMPTS attempts (last state: $launch_state)"
    fi
    echo "     iteration $i attempt $attempt: LaunchState=$launch_state, retrying" >&2
  done

  jq -nc --argjson iter "$i" --argjson warmup "$warmup" --argjson attempts "$attempt" \
        --arg launchState "${launch_state:-unknown}" \
        --argjson thisTime "${this_time:-null}" \
        --argjson totalTime "$total_time" \
        --argjson waitTime "$wait_time" \
        '{iter:$iter, warmup:$warmup, attempts:$attempts, launchState:$launchState,
          thisTimeMs:$thisTime, totalTimeMs:$totalTime, waitTimeMs:$waitTime}' >> "$RAW"

  printf '  %2d/%-2d %-7s TotalTime=%sms\n' "$i" "$total" \
    "$([ "$warmup" = true ] && echo warmup || echo measured)" "$total_time" >&2
done

perf_adb shell am force-stop "$APP_ID"

stats_total=$(jq -r 'select(.warmup|not) | .totalTimeMs' "$RAW" | perf_stats_json)
stats_wait=$(jq  -r 'select(.warmup|not) | .waitTimeMs'  "$RAW" | perf_stats_json)

# Retry burden across the whole run (warmup + measured) -- see the comment above the retry
# loop for why a discarded retry is not free even though only the kept attempt's timings
# are used in stats_total/stats_wait.
total_attempts=$(jq -s '[.[].attempts] | add' "$RAW")
max_attempts=$(jq -s '[.[].attempts] | max' "$RAW")

jq -nc \
  --arg label "$LABEL" \
  --argjson context "$(perf_context_json "$APP_ID" "$QUIET_JSON")" \
  --arg activity "$ACTIVITY" \
  --arg compileMode "$COMPILE_MODE" \
  --argjson warmups "$WARMUPS" \
  --argjson iterations "$ITERATIONS" \
  --argjson totalTimeMs "$stats_total" \
  --argjson waitTimeMs "$stats_wait" \
  --argjson totalAttempts "$total_attempts" \
  --argjson maxAttempts "$max_attempts" \
  '{label:$label, metric:"am_start_TotalTime", activity:$activity,
    compileMode:$compileMode, warmups:$warmups, iterations:$iterations,
    context:$context, totalTimeMs:$totalTimeMs, waitTimeMs:$waitTimeMs,
    totalAttempts:$totalAttempts, maxAttempts:$maxAttempts}' \
  | tee "$SUMMARY" | jq .

echo >&2
perf_log "raw:     $RAW"
perf_log "summary: $SUMMARY"
