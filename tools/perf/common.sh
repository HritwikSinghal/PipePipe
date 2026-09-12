#!/usr/bin/env bash
# Shared helpers for the PipePipeD performance rig.
# Source this; do not execute it.
#
# Conventions follow the upstream harness in PipePipeClient/tools/:
#   - one JSON object per line into a .jsonl
#   - the APK and application id are discovered from output-metadata.json, never hardcoded
#   - every capture records the conditions it ran under, so a number can be audited later
#
# See docs/perf-automation-plan.md for why each control exists.

set -euo pipefail

# --- paths -------------------------------------------------------------------------------
# ${BASH_SOURCE[0]:-$0}: under `set -u`, BASH_SOURCE can be unset when this file is sourced
# from an interactive shell or a `bash -c` one-liner, which aborts the source with an unhelpful
# "parameter not set". Falling back to $0 keeps ad-hoc sourcing (handy for poking at
# perf_stats_json by hand) working without weakening anything in normal script use.
PERF_META_ROOT="${PERF_META_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
PERF_CLIENT_DIR="$PERF_META_ROOT/PipePipeClient"
PERF_RESULTS_ROOT="${PERF_RESULTS_ROOT:-$PERF_META_ROOT/perf-results}"

perf_die() { echo "error: $*" >&2; exit 1; }
perf_log() { echo "[*] $*" >&2; }

# --- device ------------------------------------------------------------------------------

# adb honours ANDROID_SERIAL. Default to the rig's emulator so a plugged-in phone is never
# measured by accident -- mixing an emulator arm with a device arm would silently destroy an A/B.
perf_adb() { adb -s "${ANDROID_SERIAL:?ANDROID_SERIAL must be set}" "$@"; }

perf_require_device() {
  : "${ANDROID_SERIAL:=emulator-5554}"
  export ANDROID_SERIAL
  adb devices | awk -v s="$ANDROID_SERIAL" 'NR>1 && $1 == s && $2 == "device" { found=1 } END { exit !found }' \
    || perf_die "no authorised device '$ANDROID_SERIAL'. Start one with: nix run .#emulator"
  [ "$(perf_adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ] \
    || perf_die "'$ANDROID_SERIAL' has not finished booting"
  perf_wake_device
}

# A real phone dozes and locks; an emulator effectively never does. A measurement run against
# a Dozing device silently records a sleeping CPU -- no error, just meaningless numbers. Wake
# it, dismiss the keyguard, and keep it awake for the duration.
perf_wake_device() {
  local wakefulness
  perf_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  # `wm dismiss-keyguard`, not KEYCODE_MENU. MENU is the traditional unlock but on a modern
  # phone it pulls down the notification shade instead, which then sits on top of whatever we
  # are about to measure. HOME afterwards guarantees a known starting surface.
  perf_adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  perf_adb shell input keyevent KEYCODE_HOME   >/dev/null 2>&1 || true
  # stayon only holds while the device is on power, which is the normal state for a tethered
  # measurement run. It is reversible: `svc power stayon false`.
  perf_adb shell svc power stayon true >/dev/null 2>&1 || true
  wakefulness="$(perf_adb shell dumpsys power | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)"
  [ "$wakefulness" = "Awake" ] \
    || perf_die "'$ANDROID_SERIAL' is '${wakefulness:-unknown}', not Awake -- unlock it and retry"
}

# --- APK / application id ----------------------------------------------------------------

# Returns the applicationId from a variant's output-metadata.json. The fork rewrites this
# (wtf.pipepiped.debug), so reading it is the only safe way to learn the package name.
perf_app_id() {
  local variant="${1:-debug}"
  local meta="$PERF_CLIENT_DIR/app/build/outputs/apk/$variant/output-metadata.json"
  [ -f "$meta" ] || perf_die "no $meta -- build first: nix run .#debug"
  jq -r '.applicationId' "$meta"
}

perf_apk_path() {
  local variant="${1:-debug}"
  local dir="$PERF_CLIENT_DIR/app/build/outputs/apk/$variant"
  local abi apk
  abi="$(perf_adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  # The fork builds -PforkAbiFilter=universal, so prefer a universal APK and fall back to a
  # per-ABI one if someone built a split.
  apk="$(find "$dir" -maxdepth 1 -name '*universal*.apk' -print -quit 2>/dev/null || true)"
  [ -n "$apk" ] || apk="$(find "$dir" -maxdepth 1 -name "*-${abi}-*.apk" -print -quit 2>/dev/null || true)"
  [ -n "$apk" ] || apk="$(find "$dir" -maxdepth 1 -name '*.apk' -print -quit 2>/dev/null || true)"
  [ -n "$apk" ] || perf_die "no APK in $dir -- build first: nix run .#debug"
  printf '%s\n' "$apk"
}

perf_launchable_activity() {
  local app_id="$1"
  perf_adb shell cmd package resolve-activity --brief "$app_id" \
    | tr -d '\r' | tail -1
}

# Describes the binary actually ON THE DEVICE, not the source tree. clientHead/clientDirty
# (below, in perf_context_json) describe what was checked out when the harness ran -- with
# the emulator kept across runs (PIPEPIPED_EMU_WIPE=0), forgetting to `adb install` after a
# rebuild silently re-measures the OLD apk while those two fields still look correct. Prints
# "versionCode<TAB>versionName<TAB>lastUpdateTime".
perf_apk_provenance() {
  local app_id="$1" dump version_code version_name last_update
  dump="$(perf_adb shell dumpsys package "$app_id" | tr -d '\r')"
  # versionCode shares its line with minSdk/targetSdk, so stop at the first space; versionName
  # and lastUpdateTime are the only field on their line and lastUpdateTime's value itself
  # contains a space ("2026-09-12 13:48:36"), so those two capture to end-of-line instead.
  version_code="$(printf '%s\n' "$dump" | sed -n 's/^ *versionCode=\([^ ]*\).*/\1/p' | head -1)"
  version_name="$(printf '%s\n' "$dump" | sed -n 's/^ *versionName=\(.*\)/\1/p' | head -1)"
  last_update="$(printf '%s\n' "$dump"  | sed -n 's/^ *lastUpdateTime=\(.*\)/\1/p' | head -1)"
  [ -n "$version_code" ] || perf_die "could not read versionCode from dumpsys package $app_id -- is it installed?"
  [ -n "$version_name" ] || perf_die "could not read versionName from dumpsys package $app_id"
  [ -n "$last_update" ]  || perf_die "could not read lastUpdateTime from dumpsys package $app_id"
  printf '%s\t%s\t%s\n' "$version_code" "$version_name" "$last_update"
}

# --- measurement hygiene -----------------------------------------------------------------

# Reads back the ABI-specific dexopt filter dumpsys actually recorded for app_id (e.g.
# "speed", "verify") -- the only trustworthy source for what compilation state a launch ran
# under. Used both to validate a pin took effect (perf_pin_compilation) and to record the
# true state in the context JSON even when no pin was requested this run.
perf_compiler_filter() {
  local app_id="$1" actual
  # Key off the [primary-abi] marker, NOT ro.product.cpu.abi. Those two disagree on real
  # hardware: a Pixel 10a reports ro.product.cpu.abi=arm64-v8a while dumpsys prints the line
  # as "arm64: [status=...] [primary-abi]". They happen to match on an x86_64 emulator, which
  # is exactly why keying off the property looked correct until it met a phone.
  actual="$(perf_adb shell dumpsys package "$app_id" | tr -d '\r' \
             | sed -n 's/^ *[A-Za-z0-9_-]*: \[status=\([^]]*\)\].*\[primary-abi\].*/\1/p' | head -1)"
  [ -n "$actual" ] || perf_die "no [primary-abi] dexopt line in dumpsys package $app_id on $ANDROID_SERIAL"
  printf '%s\n' "$actual"
}

# Force-stop and then WAIT until the process is really gone.
# `am force-stop` is asynchronous, and this app has background work (WorkManager /
# NotificationWorker, the player service) that can respawn the process before the next
# launch -- which then measures as WARM and is a different workload entirely. A fixed sleep
# does not settle this; polling for the pid does.
perf_kill_and_settle() {
  local app_id="$1" tries="${2:-40}" pid=""
  perf_adb shell am force-stop "$app_id"
  for (( t = 0; t < tries; t++ )); do
    # `pidof` exits 1 when the process is absent -- which is the state we WANT. Without the
    # `|| true` this assignment fails under `set -e` and kills the script on success.
    pid="$(perf_adb shell pidof "$app_id" 2>/dev/null | tr -d '\r' | tr -d '[:space:]' || true)"
    [ -z "$pid" ] && return 0
    # Still alive, or respawned between the stop and the check. Stop it again.
    perf_adb shell am force-stop "$app_id"
    sleep 0.25
  done
  perf_die "$app_id kept respawning after force-stop (last pid: $pid)"
}

# Compilation state dominates startup. Pin it explicitly or early iterations measure JIT.
# `cmd package compile` reports "Success" (exit 0) even when the pin did NOT take -- confirmed
# on this rig's emulator, where `-m speed -f` exits clean but dumpsys still shows the OLD
# filter afterwards. Trusting the exit code alone records a false compileMode, so read the
# filter back and treat a mismatch as fatal by default; set PERF_ALLOW_COMPILE_MISMATCH=1 to
# proceed anyway (the harness will still record the true, mismatched filter, never the
# requested one, so a downstream reader is never told a pin worked when it did not).
perf_pin_compilation() {
  local app_id="$1" mode="${2:-speed}" actual
  perf_log "pinning compilation: $mode"
  perf_adb shell cmd package compile -m "$mode" -f "$app_id" >/dev/null

  actual="$(perf_compiler_filter "$app_id")"
  if [ "$actual" != "$mode" ] && [ -z "${PERF_ALLOW_COMPILE_MISMATCH:-}" ]; then
    perf_die "compile pin did not take for $app_id: requested '$mode', dumpsys reports '$actual'" \
      "(set PERF_ALLOW_COMPILE_MISMATCH=1 to proceed anyway and record the mismatch)"
  fi
  [ "$actual" = "$mode" ] || perf_log "warning: proceeding with compiler filter '$actual' != requested '$mode' (PERF_ALLOW_COMPILE_MISMATCH=1)"
}

# Reports whether the animation-scale settings that most inflate cold-start / frame timings
# are actually off, plus the three raw values -- as JSON on stdout, so a caller can both
# decide whether a noisy device is fatal (coldstart.sh does; scroll.sh tolerates it) AND
# record what was really measured under, rather than a bare pass/fail that nothing keeps.
# Exit status is still 0 (quiet) / 1 (noisy) for a caller that only wants `|| true`.
perf_assert_quiet_device() {
  local win trans anim value quiet=true
  win="$(perf_adb shell settings get global window_animation_scale | tr -d '\r')"
  trans="$(perf_adb shell settings get global transition_animation_scale | tr -d '\r')"
  anim="$(perf_adb shell settings get global animator_duration_scale | tr -d '\r')"
  for value in "$win" "$trans" "$anim"; do
    case "$value" in
      0|0.0) ;;
      *) quiet=false ;;
    esac
  done
  [ "$quiet" = true ] \
    || echo "warning: animations not fully disabled (window=$win transition=$trans animator=$anim) -- this will inflate frame counts / timings" >&2
  jq -nc --arg win "$win" --arg trans "$trans" --arg anim "$anim" --argjson quiet "$quiet" \
    '{windowAnimationScale:$win, transitionAnimationScale:$trans, animatorDurationScale:$anim, quiet:$quiet}'
  [ "$quiet" = true ]
}

# Records the conditions a capture ran under. A number without these is an anecdote.
#
# animation_json is optional: coldstart.sh already queried and enforced quiet-device state
# before running and passes that exact reading through, so the recorded state matches what
# was enforced. A caller that does not have it (scroll.sh, unchanged) gets a fresh query here
# for free.
perf_context_json() {
  local app_id="$1" animation_json="${2:-}"
  local sdk abi build_type fingerprint host_governor host_no_turbo client_head client_dirty utc
  local apk_version_code apk_version_name apk_last_update compiler_filter

  # Device fields below are load-bearing for interpreting a result later (sdk gates
  # behaviour, fingerprint identifies the exact system image) -- capture each into a plain
  # variable and validate it explicitly, rather than inlining the substitution inside a jq
  # --arg. Inline, a failed/empty read under set -e + pipefail does NOT abort the script --
  # jq is the simple command being run, not the substitution, so jq just receives "" and
  # emits a complete-looking record with a silently blank field. Confirmed by repro.
  sdk="$(perf_adb shell getprop ro.build.version.sdk | tr -d '\r')"
  [ -n "$sdk" ] || perf_die "empty ro.build.version.sdk from $ANDROID_SERIAL"
  abi="$(perf_adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  [ -n "$abi" ] || perf_die "empty ro.product.cpu.abi from $ANDROID_SERIAL"
  build_type="$(perf_adb shell getprop ro.build.type | tr -d '\r')"
  [ -n "$build_type" ] || perf_die "empty ro.build.type from $ANDROID_SERIAL"
  fingerprint="$(perf_adb shell getprop ro.build.fingerprint | tr -d '\r')"
  [ -n "$fingerprint" ] || perf_die "empty ro.build.fingerprint from $ANDROID_SERIAL"

  # Host fields are genuinely absent on a non-Intel host or off Linux -- "unknown" there is a
  # true reading, not a swallowed failure, so these stay tolerant.
  host_governor="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  host_no_turbo="$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo unknown)"
  client_head="$(git -C "$PERF_CLIENT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  client_dirty="$(test -n "$(git -C "$PERF_CLIENT_DIR" status --porcelain 2>/dev/null)" && echo true || echo false)"
  utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # APK provenance: the binary actually on the device, not the source tree -- see
  # perf_apk_provenance for why clientHead/clientDirty alone can't be trusted for this.
  # Captured into a bare variable FIRST, not inlined into `read <<< "$(...)"` directly: a
  # `read`/`IFS` herestring is, once again, the executed command, so a perf_die inside the
  # substitution would print its error and then be silently swallowed -- read just sees an
  # empty line and happily returns 0, continuing with blank fields. The assignment below is
  # a bare simple command, so its failure DOES trigger set -e, same fix as CRITICAL 1 above.
  local apk_line
  apk_line="$(perf_apk_provenance "$app_id")"
  IFS=$'\t' read -r apk_version_code apk_version_name apk_last_update <<< "$apk_line"

  # Same reasoning as compilation pinning: this is the ACTUAL filter dumpsys reports right
  # now, not merely what a caller asked for -- see perf_pin_compilation.
  compiler_filter="$(perf_compiler_filter "$app_id")"

  if [ -z "$animation_json" ]; then
    animation_json="$(perf_assert_quiet_device)" || true
  fi

  jq -nc \
    --arg serial            "$ANDROID_SERIAL" \
    --arg appId             "$app_id" \
    --arg sdk               "$sdk" \
    --arg abi               "$abi" \
    --arg buildType         "$build_type" \
    --arg fingerprint       "$fingerprint" \
    --arg hostGovernor      "$host_governor" \
    --arg hostNoTurbo       "$host_no_turbo" \
    --arg clientHead        "$client_head" \
    --arg clientDirty       "$client_dirty" \
    --arg apkVersionCode    "$apk_version_code" \
    --arg apkVersionName    "$apk_version_name" \
    --arg apkLastUpdateTime "$apk_last_update" \
    --arg compilerFilter    "$compiler_filter" \
    --argjson animations    "$animation_json" \
    --arg utc               "$utc" \
    '{serial:$serial, appId:$appId, sdk:$sdk, abi:$abi, buildType:$buildType,
      fingerprint:$fingerprint, hostGovernor:$hostGovernor, hostNoTurbo:$hostNoTurbo,
      clientHead:$clientHead, clientDirty:($clientDirty=="true"),
      apkVersionCode:$apkVersionCode, apkVersionName:$apkVersionName,
      apkLastUpdateTime:$apkLastUpdateTime, compilerFilter:$compilerFilter,
      animations:$animations, capturedAtUtc:$utc}'
}

# --- statistics --------------------------------------------------------------------------

# Reads one number per line on stdin, emits a JSON object.
# Reports median and spread, never a bare mean -- a single number hides the variance that
# decides whether a later delta means anything.
perf_stats_json() {
  sort -n | awk '
    { v[NR] = $1; sum += $1 }
    # Linear interpolation between the two closest ranks (the "R-7" / NumPy-default /
    # Excel PERCENTILE method), NOT int(p*(n-1))+1: that floored form always lands on an
    # actual sample and, for n<=20, p95 floors to the same index as p5 (both hit v[1]) --
    # and at n=2 [100,200] it produces p95=100, BELOW the median of 150. An invalid
    # ordering is worse than an imprecise one.
    function pct(p,    h, lo, hi, frac) {
      h = 1 + p * (n - 1)
      lo = int(h)
      hi = lo + 1
      frac = h - lo
      if (hi > n) return v[n]
      if (lo < 1) return v[1]
      return v[lo] + frac * (v[hi] - v[lo])
    }
    END {
      if (NR == 0) { print "{\"n\":0}"; exit }
      n = NR
      mean = sum / n
      for (i = 1; i <= n; i++) { d = v[i] - mean; ss += d * d }
      sd = (n > 1) ? sqrt(ss / (n - 1)) : 0
      med = (n % 2) ? v[(n+1)/2] : (v[n/2] + v[n/2+1]) / 2
      p5  = pct(0.05)
      p95 = pct(0.95)
      cv  = (mean > 0) ? sd / mean : 0
      printf "{\"n\":%d,\"min\":%.2f,\"p5\":%.2f,\"median\":%.2f,\"p95\":%.2f,\"max\":%.2f,\"mean\":%.2f,\"stddev\":%.2f,\"cv\":%.4f}",
             n, v[1], p5, med, p95, v[n], mean, sd, cv
    }'
}

perf_new_run_dir() {
  local label="$1"
  local stamp dir
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  dir="$PERF_RESULTS_ROOT/$stamp-$label"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}
