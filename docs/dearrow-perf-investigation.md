# DeArrow performance & reliability investigation (Session 11 — 2026-05-31)

> **Resume pointer.** Root cause found; the fix is **IMPLEMENTED and on-device VERIFIED
> (Session 12, 2026-06-01)** — all 3 parts. See **"Verification (Session 12)"** below for the
> before/after numbers. Remaining: commit (client `patch` BEFORE the meta gitlink bump) and decide
> whether to keep the `DeArrowPerf` instrumentation long-term.

## TL;DR

Two user-reported symptoms — (1) DeArrow titles/thumbnails update **very slowly** in lists
(home feed, recommended-below-player), and (2) DeArrow **sometimes doesn't load at all** on the
video page — are the **same root disease**:

**We over-fetch a rate-limited API (`sponsor.ajay.app`), it responds with 5xx + multi-second
latency, and then we cache those failures for 6 hours.**

The DeArrow browser extension "nails it every time" because it only resolves the items **on
screen** (~20–40) and caches; we burst the **entire feed** (500 items) on every load.

## What was changed this session (UNCOMMITTED — diagnostic instrumentation only, no fix yet)

All gated behind `BuildConfig.DEBUG`, so they are **compiled out of release builds** and are safe to
leave in place while iterating. Logcat tag: **`DeArrowPerf`**.

Client (`PipePipeClient`, working tree on `patch` @ `3f39eb780`):
- `app/.../util/dearrow/DeArrowService.java` — bucket **HIT/MISS** log; `fetchBucket` logs HTTP
  code + entry count + **fetch latency**; `doOnError` logs swallowed errors.
- `app/.../util/dearrow/DeArrowItemController.java` — per-row resolve latency + outcome
  (`title=`/`thumb=`), plus `EMPTY` / `DROPPED (recycled)` / `ERROR` branches (3-arg `subscribe`).
- `app/.../util/dearrow/DeArrowPrefetcher.java` — logs prefetch **page size** and total
  **page-warm time**.
- `app/.../util/PicassoHelper.java` — `setIndicatorsEnabled(true)` in debug (source ribbons; note:
  user reported no ribbon appeared — secondary, logcat was conclusive anyway).

Meta (`PipePipe`, working tree on `patch` @ `fe888fb`):
- `.github/workflows/release.yml` — added an `assembleDebug` step that also publishes the
  **"PipePipeD Debug"** APK (`wtf.pipepiped.debug`) to the release. *(Requested by
  the user so the instrumented build can be installed via Obtainium; works alongside the release build.)*

> Decision still open: whether the bare `nix run` (currently `= .#build` = signed release) should
> default to `.#debug`. For now use `nix run .#debug` for the instrumented build. The instrumentation
> needs the **debug** buildType (release has `BuildConfig.DEBUG == false`, so logs are compiled out).

## How the evidence was gathered

1. `nix run .#debug` → built 5 debug APKs (BUILD SUCCESSFUL ~30s incremental).
2. `adb install -r .../apk/debug/PipePipe_5.1.1-arm64-v8a-debug.apk` onto a **Pixel 10a, Android 16,
   arm64-v8a** (wireless adb `192.168.1.40`). Installs as **"PipePipeD Debug"**, separate from the release build.
3. `adb logcat -c` then `adb logcat -v time DeArrowPerf:V '*:S'` while the user used the app
   (opened videos, scrolled recommended lists + the home feed).

## Evidence (on-device logcat, full capture)

| Metric | Value |
|---|---|
| HTTP responses from `sponsor.ajay.app` | 219× **200** · 78× **503** · 27× **502** → **~32% 5xx** (+1 `SocketTimeoutException`) |
| Branding fetch latency (n=492) | **median 7.7 s** · p90 13.0 s · **max 105 s** · mean 7.8 s |
| Fetches > 3 s | ~77% |
| Prefetch pages fired | **5×500-item** (home feed) + 21×20-item + 70/64/63 |
| Worst prefetch page-warm time | **105 s** to warm one page |
| Per-row resolves | 146 with data, 103 EMPTY (many resolves took **7–13 s** to land) |

Representative lines:

```
prefetch page: 500 items, titles=true thumbs=true (concurrency=4)
fetch ce8e code=502 (negative-cached) in 2603ms
fetch e031 code=503 (negative-cached) in 4286ms
fetch 6fe0 code=200 entries=134 in 13657ms
fetch 2368 FAILED, kept original (no retry): java.net.SocketTimeoutException: timeout
resolve sHjFfBNyeF4 in 12250ms title=true thumb=true
prefetch page done in 105265ms
```

## Root causes

### RC1 — Over-aggressive prefetch (self-inflicted overload) → the latency
`FeedFragment.handleLoadedState` (`FeedFragment.kt:764`) prefetches the **entire feed** — observed
**500 items = ~500 bucket requests** — on load, and **every navigation fires another full page**
(`InfoListAdapter.addInfoItemList`/`setInfoItemList`, `LocalItemListAdapter.addItems`). At
`MAX_CONCURRENCY = 4` against the **single host** `sponsor.ajay.app`, this floods it: the server
returns 502/503 and latency climbs from ~2.6 s early to 7–105 s as the backlog grows. We are
effectively rate-limiting ourselves. (Bind-time fetches in `DeArrowItemController` are *unbounded*
`Schedulers.io()`, which can pile on further during fast scroll.)

### RC2 — Transient failures are negative-cached for 6 h → the "sometimes never loads"
`DeArrowService.fetchBucket` (`DeArrowService.java`, the `response.responseCode() != HTTP_OK` branch)
negative-caches **any** non-200 — including 502/503 — as an empty bucket (`BucketResult(emptyMap)`)
with the **6-hour TTL** (`CACHE_TTL_MS`). With ~32% of requests 5xx-ing, a large share of buckets get
a **false "no data"** cached, so those videos show the original until the TTL expires or the app
restarts (the in-memory `LruCache` dies on process death). The code comment claims *"404 means no
branding"* but the code does not distinguish 404 from 5xx. On the **single-shot detail page** one
blip = a total miss, with **no retry** (`getBranding(...).subscribe(onSuccess, error->{})` swallows;
service ends in `.onErrorComplete()`).

RC1 and RC2 compound: more load → more 5xx → more poisoned buckets → more apparent "no data".

## Approved fix (all 3 parts — IMPLEMENTED Session 12, on-device verified)

1. **Only cache 404 as "no data."** In `DeArrowService.fetchBucket`, treat **404** as the genuine
   negative (cache empty bucket). Treat **5xx / 429 / network / timeout** as **transient**: do NOT
   cache, surface as an error so it can retry and so a later view re-fetches. (Today every non-200 is
   cached.)
2. **Slash prefetch volume.** In `DeArrowPrefetcher.prefetch`, cap to a **small viewport window
   (~25 items, tunable)** instead of the whole page, and drop **`MAX_CONCURRENCY` 4 → 2**. This
   removes the burst that triggers the 5xx storm. Bind-time fetching (viewport-driven) covers the
   rest; consider also bounding bind-time concurrency if fast-scroll still overloads.
3. **Bounded retry with backoff** on transient errors only (e.g. 2 attempts, exponential backoff),
   so the one-shot detail page recovers instead of showing the original. Keep retries small so they
   don't re-introduce load.

Optional follow-ups (not in scope unless needed after re-measuring):
- Persistent (disk) branding cache so cold app starts don't re-fetch every bucket.
- Honor `Retry-After` on 429; back off globally when the recent 5xx rate is high.

### Exact code locations
- `PipePipeClient/app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowService.java`
  — `fetchBucket()` (404-vs-transient split + retry) and the `bucket()`/cache TTL logic.
- `PipePipeClient/app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowPrefetcher.java`
  — `prefetch()` (window cap) and `MAX_CONCURRENCY`.
- `PipePipeClient/app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowItemController.java`
  — bind-time `getBranding` subscription (error handling; optional concurrency bound).

## Verification (Session 12 — on-device, Pixel 10a, fix installed)

Implemented all 3 parts on client `patch` (working tree, uncommitted), rebuilt the instrumented
debug APK (`nix run .#debug`), reinstalled, and re-captured `DeArrowPerf` during the same usage flow
(home feed scroll + several video opens). **All three parts confirmed working; both symptoms
addressed.** Compile clean; dearrow unit suite **46/46** green (no regression).

| Metric | Baseline (before) | After fix |
|---|---|---|
| Prefetch burst | 500 items @ concurrency 4 | **first 25 @ concurrency 2** (cap confirmed in logs) |
| 5xx rate | ~28–32% | **~9.5%** (45 / 472) |
| **Negative-cached buckets** | **44 — all 5xx-poisoned** | **0** (only 404s would cache; 0 occurred) |
| Transient 5xx handling | poisoned 6h (false "no data") | **NOT cached**; retried — 44/45 recovered, 1 gave up (uncached) |
| Branding fetch latency | median 7.8 s · 89% >3 s | **median 0.4 s · 20% >3 s** |
| Per-row resolve latency | many 7–13 s | **median 35 ms** (655 warm-cache HITs) |

- **Part 1 (404-only negative cache):** 0 negative-cached buckets vs 44; every 5xx now logs
  `(transient, NOT cached)`. RC2 eliminated.
- **Part 2 (prefetch window + concurrency):** every 500/58/59/30-item page now logs
  `warming first 25 … concurrency=2`. The RC1 burst is gone.
- **Part 3 (bounded retry w/ backoff):** 35× `retry 1/2 in 500ms`, 9× `retry 2/2 in 1000ms`,
  1× `FAILED after retries` (a bucket that 503'd 3×, left uncached). Transient blips recover
  instead of poisoning.

**Remaining latency tail (honest).** p90 fetch ~8.5 s / max ~36 s persists because the DeArrow
server itself is sometimes slow (observed a **15 s** wait just to *receive* a 503) and still 5xx's
even at the reduced load — server-side, not self-inflicted. The warm-cache prefetch hides most of it
(median resolve 35 ms). If the tail still bothers the user, the optional follow-ups apply: a
**shorter per-request timeout** (fail fast on a stuck request → retry/give up sooner), a
**persistent disk cache** (cold starts don't re-fetch), and **global backoff / honor `Retry-After`**
when the recent 5xx rate is high.

## How to resume (commands)

```bash
# 0. Catch up: read this file + docs/progress.md (Session 11 note).

# 1. Implement the 3-part fix in the files above (instrumentation can stay; it's BuildConfig.DEBUG-gated).

# 2. Rebuild the instrumented debug APK + reinstall on the connected phone:
META_ROOT=/home/hritwik/Projects/PipePipe nix run /home/hritwik/Projects/PipePipe#debug
adb install -r /home/hritwik/Projects/PipePipe/PipePipeClient/app/build/outputs/apk/debug/PipePipe_5.1.1-arm64-v8a-debug.apk

# 3. Re-capture and compare against the baseline table above (expect 5xx rate ↓, median latency ↓,
#    prefetch page size ≤ ~25, far fewer EMPTY resolves):
adb logcat -c && adb logcat -v time DeArrowPerf:V '*:S'

# 4. Unit tests (dearrow suite, expect 46/46):
cd PipePipeClient && nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.*'
```

Test device: **Pixel 10a / Android 16 / arm64-v8a**, wireless adb (re-pair if the IP changed).
Debug app package: `wtf.pipepiped.debug` ("PipePipeD Debug").

## Decisions / notes
- The instrumentation (`DeArrowPerf` logs + Picasso ribbons) is intentionally **kept** in the working
  tree as a `BuildConfig.DEBUG`-gated diagnostic harness for verifying the fix. Decide at commit time
  whether to keep it long-term or strip it.
- TDD opportunity: a pure unit test asserting `fetchBucket` caches **404** but not **503/502/timeout**
  would have caught RC2 (`DeArrowResponseParser`/service is already unit-tested — extend that suite).
- Before committing the fix: push **client `patch` before** the meta gitlink bump (per the standing
  gotcha in `docs/progress.md`).
