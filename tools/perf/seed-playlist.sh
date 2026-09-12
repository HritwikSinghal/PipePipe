#!/usr/bin/env bash
# Seeds a deterministic, fully offline local playlist for the scroll-jank benchmark.
#
#   tools/perf/seed-playlist.sh [name]              seed (idempotent) + verify DB + verify on screen
#   tools/perf/seed-playlist.sh --verify [name]      verify only, no writes
#   tools/perf/seed-playlist.sh navigate [name]      land the app on an already-seeded playlist
#
# Env knobs:
#   ITEM_COUNT       stream rows to seed              (default 500)
#   PLAYLIST_NAME    playlist name (overridden by the positional arg if given)
#                                                      (default PerfSeed500)
#   ANDROID_SERIAL                                     (default emulator-5554)
#
# WHY THIS IS NETWORK-FREE, so a scroll benchmark measures the app and not YouTube:
#   - service_id 1 is SoundCloud. DeArrowVideoIds.of() returns null unless serviceId is
#     YouTube (0), so DeArrow short-circuits before any fetch regardless of its setting.
#   - thumbnail_url is left NULL, so Picasso renders the local dummy_thumbnail placeholder
#     with no HTTP request.
#
# HOW IT WRITES, so re-running is safe:
#   `run-as <pkg> sqlite3 <db>` talks to the live Room WAL database directly -- no file
#   push, no -wal/-shm juggling. The whole seed is one script piped over stdin (never as
#   adb argv -- adb's remote shell re-tokenizes a multi-word argv element on spaces, which
#   silently turns `.schema streams` into two separate sqlite3 "commands"). It runs under
#   `sqlite3 -bail` inside one BEGIN/COMMIT: any failing statement skips COMMIT, and an
#   uncommitted transaction is discarded when the connection closes, so a partial write
#   can never be observed. Before inserting, it deletes any existing playlist row of the
#   same name and every stream whose url carries this playlist's seed prefix, so re-running
#   (including with a different ITEM_COUNT) replaces rather than duplicates.
#
# ON-SCREEN VERIFICATION:
#   There is no `am start` deep link for a local playlist by id -- MainActivity.handleIntent()
#   only special-cases STREAM/CHANNEL/PLAYLIST(remote) intents, and local playlists open
#   exclusively via BookmarkFragment's item click into LocalPlaylistFragment.getInstance(id).
#   So getting there is UI automation: dump the a11y tree, tap by matching TEXT/content-desc,
#   never by hardcoded pixels (a different AVD skin or font scale would silently mis-tap).

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ITEM_COUNT="${ITEM_COUNT:-500}"

MODE="seed"
NAME_ARG=""
for arg in "$@"; do
  case "$arg" in
    --verify) MODE="verify" ;;
    navigate) MODE="navigate" ;;
    *) NAME_ARG="$arg" ;;
  esac
done
PLAYLIST_NAME="${NAME_ARG:-${PLAYLIST_NAME:-PerfSeed500}}"

[[ "$ITEM_COUNT" =~ ^[1-9][0-9]{0,4}$ ]] \
  || perf_die "ITEM_COUNT must be an integer in 1..99999, got '$ITEM_COUNT'"
case "$PLAYLIST_NAME" in
  *[\"\&\<\>]*) perf_die "PLAYLIST_NAME must not contain \" & < > (it is matched against the on-device a11y XML dump verbatim)" ;;
esac

perf_require_device
APP_ID="$(perf_app_id debug)"
ACTIVITY="$(perf_launchable_activity "$APP_ID")"
[ -n "$ACTIVITY" ] || perf_die "could not resolve a launchable activity for $APP_ID"
DB_PATH="/data/data/$APP_ID/databases/newpipe.db"

perf_adb shell run-as "$APP_ID" test -f "$DB_PATH" \
  || perf_die "$DB_PATH does not exist under run-as -- launch $APP_ID at least once first"
perf_adb shell command -v sqlite3 >/dev/null \
  || perf_die "no sqlite3 on device -- expected /system/bin/sqlite3"

# Every seeded row lives under this url prefix, so idempotent cleanup and on-screen
# identification never touch unrelated data. '-' cannot collide with SQL LIKE wildcards
# (% and _), so the LIKE clauses below need no ESCAPE clause.
SLUG="$(printf '%s' "$PLAYLIST_NAME" | tr -c 'A-Za-z0-9' '-')"
URL_PREFIX="https://soundcloud.com/perfseed/${SLUG}/stream-"

# --- sqlite helpers ------------------------------------------------------------------------

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
NAME_ESC="$(sql_escape "$PLAYLIST_NAME")"

# Runs a SQL script piped on stdin against the live app DB via run-as. -bail stops on the
# first error so a failing statement mid-script never reaches COMMIT.
run_sql() { perf_adb shell run-as "$APP_ID" sqlite3 -bail "$DB_PATH"; }

# Runs a single query (no side effects expected) and returns its bare output.
query_sql() { printf '%s\n' "$1" | run_sql; }

seed_sql() {
  cat <<SQL
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
DELETE FROM playlist_stream_join
 WHERE playlist_id IN (SELECT uid FROM playlists WHERE name = '$NAME_ESC');
DELETE FROM streams
 WHERE url LIKE '$URL_PREFIX%';
DELETE FROM playlists WHERE name = '$NAME_ESC';
INSERT INTO playlists (name, thumbnail_url, display_index)
VALUES ('$NAME_ESC', NULL, 0);
INSERT INTO streams (service_id, url, title, stream_type, duration, uploader,
                      uploader_url, thumbnail_url, view_count,
                      textual_upload_date, upload_date, is_upload_date_approximation, is_paid)
SELECT 1,
       '$URL_PREFIX' || printf('%05d', n),
       'Perf Seed Stream ' || n,
       'VIDEO_STREAM', 180, 'PerfSeed Uploader',
       NULL, NULL, 1000, NULL, NULL, 0, 0
  FROM (WITH RECURSIVE seq(n) AS (
          SELECT 1
          UNION ALL
          SELECT n + 1 FROM seq WHERE n < $ITEM_COUNT
        )
        SELECT n FROM seq);
INSERT INTO playlist_stream_join (playlist_id, stream_id, join_index)
SELECT (SELECT uid FROM playlists WHERE name = '$NAME_ESC'),
       s.uid,
       CAST(substr(s.url, -5) AS INTEGER) - 1
  FROM streams s
 WHERE s.url LIKE '$URL_PREFIX%';
COMMIT;
SQL
}

# perf_dies unless the DB holds exactly ITEM_COUNT seeded streams/joins under one playlist row.
verify_db_counts() {
  local playlist_uid stream_count join_count
  playlist_uid="$(query_sql "SELECT uid FROM playlists WHERE name = '$NAME_ESC';" | tr -d '[:space:]')"
  [ -n "$playlist_uid" ] || perf_die "no playlist named '$PLAYLIST_NAME' in the DB"

  stream_count="$(query_sql "SELECT COUNT(*) FROM streams WHERE url LIKE '$URL_PREFIX%';" | tr -d '[:space:]')"
  [ "$stream_count" = "$ITEM_COUNT" ] \
    || perf_die "expected $ITEM_COUNT seeded streams, found $stream_count"

  join_count="$(query_sql "SELECT COUNT(*) FROM playlist_stream_join WHERE playlist_id = $playlist_uid;" | tr -d '[:space:]')"
  [ "$join_count" = "$ITEM_COUNT" ] \
    || perf_die "expected $ITEM_COUNT playlist_stream_join rows, found $join_count"

  perf_log "DB verified: playlist uid=$playlist_uid, streams=$stream_count, joins=$join_count"
}

# --- UI automation ---------------------------------------------------------------------------

UI_DUMP="$(mktemp -t seed-playlist-dump-XXXXXX.xml)"
trap 'rm -f "$UI_DUMP"' EXIT

dump_ui() { perf_adb exec-out uiautomator dump /dev/tty 2>/dev/null > "$UI_DUMP"; }

# BRE-escapes the metacharacters grep -o's pattern below is sensitive to, so a playlist name
# containing e.g. '.' or '*' is matched literally instead of as a wildcard.
bre_escape() { printf '%s' "$1" | sed -e 's/[.[\*^$]/\\&/g'; }

# Prints "x1 y1 x2 y2" for the first node whose tag matches the given grep -o pattern, or
# nothing (and a non-zero exit) if no such node is on screen right now.
#
# CRITICAL: extracted with a real regex, not `tr -d '[]'` -- the latter merges adjacent
# bounds like "[800,1618][976,1767]" into "800,1618976,1767" and sends every tap off-screen.
node_bounds() {
  local pattern="$1" line
  line="$(grep -m1 -o "$pattern" "$UI_DUMP")" || return 1
  printf '%s' "$line" | sed -nE 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/p'
}

tap_bounds() {
  local x1="$1" y1="$2" x2="$3" y2="$4"
  perf_adb shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
}

# Dismisses up to a handful of sequential first-run dialogs. android:id/button1 only exists
# while an AlertDialog-style dialog is on screen, so its presence doubles as "a dialog is up".
# Tapping button1 blindly is NOT safe: only "Announcement" / "What's New" are purely
# informational. Anything else may be offering to change a setting, and its button1 can be
# "go to Settings" rather than "dismiss" -- for those, button2 (cancel/dismiss) is the safe tap.
dismiss_known_dialogs() {
  local tries=0 b1 b2
  while [ "$tries" -lt 5 ]; do
    dump_ui
    b1="$(node_bounds '<node[^>]*resource-id="android:id/button1"[^>]*>')" || return 0
    if grep -q 'text="Announcement"' "$UI_DUMP" || grep -q "text=\"What's New\"" "$UI_DUMP"; then
      perf_log "dismissing informational first-run dialog (button1)"
      # shellcheck disable=SC2086
      tap_bounds $b1
    else
      b2="$(node_bounds '<node[^>]*resource-id="android:id/button2"[^>]*>')" \
        || perf_die "an unrecognised dialog is on screen with no button2 -- refusing to blind-tap button1 (it can open Settings)"
      perf_log "dismissing unrecognised dialog via button2 (never button1, which can open Settings)"
      # shellcheck disable=SC2086
      tap_bounds $b2
    fi
    sleep 1
    tries=$(( tries + 1 ))
  done
  perf_die "still dismissing dialogs after $tries attempts"
}

# Force-stops, launches, dismisses first-run dialogs, taps into Bookmarks then the named
# playlist, and perf_dies unless items_list ends up on screen. Leaves the app sitting there.
navigate_to_playlist() {
  local top b

  perf_kill_and_settle "$APP_ID"
  perf_adb shell am start -W -S -n "$ACTIVITY" >/dev/null
  sleep 3
  dismiss_known_dialogs

  dump_ui
  top="$(perf_adb shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity || true)"
  case "$top" in
    *"$APP_ID"*) : ;;
    *) perf_die "app is not foreground after launch; top was: ${top:-<none>}" ;;
  esac

  # Tab order on a fresh profile is [DEFAULT_KIOSK, SUBSCRIPTIONS, BOOKMARKS]; found by
  # content-desc rather than a hardcoded index -- these tabs are icon-only, no visible text.
  b="$(node_bounds '<node[^>]*content-desc="Bookmarked Playlists"[^>]*>')" \
    || perf_die "could not find the Bookmarked Playlists tab on screen"
  # shellcheck disable=SC2086
  tap_bounds $b
  sleep 1.5

  dump_ui
  b="$(node_bounds "<node[^>]*text=\"$(bre_escape "$PLAYLIST_NAME")\"[^>]*>")" \
    || perf_die "playlist '$PLAYLIST_NAME' is not visible on the Bookmarks screen -- was it seeded?"
  # The title TextView itself isn't clickable, but tapping its bounds still lands inside the
  # enclosing clickable itemRoot (verified: standard Android touch-dispatch bubbling).
  # shellcheck disable=SC2086
  tap_bounds $b
  sleep 1.5

  dump_ui
  grep -q "resource-id=\"$APP_ID:id/items_list\"" "$UI_DUMP" \
    || perf_die "playlist screen for '$PLAYLIST_NAME' did not render items_list"

  local shown
  shown="$(grep -o 'text="Perf Seed Stream [0-9]\+"' "$UI_DUMP" | wc -l)"
  perf_log "on screen: items_list present, $shown seeded row(s) visible in the current viewport"
}

print_reuse_instructions() {
  echo >&2
  perf_log "no 'am start' deep link exists for a local playlist by id (MainActivity.handleIntent"
  perf_log "has no such case -- local playlists only open via a Bookmarks tap). Reuse this instead"
  perf_log "of SCROLL_TARGET, immediately before a scroll/measurement pass:"
  perf_log "  ANDROID_SERIAL=$ANDROID_SERIAL PLAYLIST_NAME='$PLAYLIST_NAME' tools/perf/seed-playlist.sh navigate '$PLAYLIST_NAME'"
}

# --- main --------------------------------------------------------------------------------

perf_log "app:      $APP_ID"
perf_log "playlist: $PLAYLIST_NAME (url prefix: ${URL_PREFIX}*)"
perf_log "mode:     $MODE"

case "$MODE" in
  seed)
    perf_log "seeding $ITEM_COUNT streams (force-stopping $APP_ID first)"
    perf_kill_and_settle "$APP_ID"
    seed_sql | run_sql
    verify_db_counts
    navigate_to_playlist
    print_reuse_instructions
    ;;
  verify)
    verify_db_counts
    navigate_to_playlist
    print_reuse_instructions
    ;;
  navigate)
    navigate_to_playlist
    print_reuse_instructions
    ;;
  *)
    perf_die "unknown mode: $MODE"
    ;;
esac
