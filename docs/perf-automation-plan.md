---
name: perf-automation
description: Automated performance testing and optimization for PipePipeD -- the emulator
  and Pixel 10a measurement rig, tools/perf harness, cold-start and scroll-jank baselines with
  noise floors, and the per-candidate optimization campaign (scroll jank, app startup,
  RecyclerView bind cost, frame timing, Macrobenchmark).
status: paused 2026-09-12 -- rig built and calibrated, first candidate measured and refuted,
  zero app performance improvements shipped so far. Next: candidate C3 (App.onCreate).
---

# Automated performance testing -- rig, baselines, and campaign

## Resume here

Two local, unpushed, signed commits on meta (`f7b5c77` build(nix), `62f45eb` perf harness) plus
client `374988dd2`. **The user force-pushes these themselves.**

**Zero app performance improvements shipped so far.** The rig exists and is calibrated; the
first candidate was measured and correctly killed. Do not mistake the tooling for a win.

**Next action: candidate C3.** `App.java:88-167` runs a WebView `warmUp()` (`:133-136`),
`PicassoHelper.init` (`:151-157`), a DeArrow disk-cache open (`:161`), six notification-channel
builds (`:144`) and prefs I/O (`:122`) -- all synchronously on the main thread. C3 is better
positioned than C1 was because it runs *before the app has a frame*, so nothing can hide in
slack, which is the exact failure mode that killed C1. Cold start is 389.75 ms on the Pixel with
a 13 ms floor, so a stage must save >13 ms to count.

Procedure, and the order matters: instrument the five stages with `PlaybackStartupTrace`-style
JSON markers on a THROWAWAY branch, attribute the breakdown, and decline anything under the
floor **without writing a fix**. Only then A/B. C1 was lost by reasoning from component cost
instead of critical-path attribution; do not repeat it.

**Rig state as left:** emulator shut down. Pixel 10a restored to normal (animations `1.0`,
background dexopt re-enabled) and both test APKs uninstalled. Re-arm with `nix run .#emulator`
and/or `nix run .#benchmark` plus an install. Emulator is a good cold-start rig and a poor jank
rig; the phone is good for both.
> Scope: stand up an emulator rig this laptop can drive unattended, add profiling
> instrumentation to the app, and run a measurement-first optimization campaign.

## TL;DR

Scroll jank on a seeded 500-item local playlist is the first metric, because it is the
only user-visible journey that can be made fully offline and therefore repeatable. The
rig is an x86_64 API-36 emulator provisioned from `flake.nix`. No app code changes until
Phase 1 produces a baseline **and** a noise floor, because on a swiftshader emulator the
noise floor may turn out wider than the effects worth chasing -- and if it does, the
correct answer is to move measurement to the Pixel 10a, not to build a rig that
manufactures confident noise.

The strongest existing suspect -- a blocking Room query on every `onBindViewHolder` -- is
recorded below as a **hypothesis**, not a finding. It gets a computed ceiling and an
adversarial check before anyone edits it.

## Measured so far (2026-09-12)

### The rig works

`nix run .#emulator` boots a pinned AVD headless in **~28 s** and leaves it measurement-ready.
Verified from the emulator's own log that swiftshader is genuinely in effect
(`vulkan_mode_selected:swiftshader gles_mode_selected:swiftshader`,
`OpenGL ES 3.0 SwiftShader 4.0.0.1`) at `androidboot.qemu.vsync=60`, and from the guest that
the pinning took: 4 cores, 4013820 kB RAM, `userdebug` (so `adb root` is available), sdk 36,
x86_64. All three animation scales read `0.0`.

The app installs and runs: `LaunchState: COLD`, no crash, live YouTube data. The main list
renders `itemRoot` / `itemThumbnailView` rows from `list_stream_item.xml` inside `items_list`,
i.e. the **legacy View holders are the active path**, so the `blockingGet()` candidate C1 is
live and not bypassed by the Compose flag.

**Build closure is provably untouched** by the emulator addition -- `pipepiped-build.drv`
hashes to `7y98a1wxyckmsqj7i4xly225ph14qghx` both with and without the change.

### Cold-start baseline and noise floor

Metric: `am start -W -S` `TotalTime`, `wtf.pipepiped.debug/org.schabi.newpipe.MainActivity`,
compilation pinned with `cmd package compile -m speed -f`, 3 warmups discarded, n=15 measured
per arm, host CPU **not** pinned (`powersave` governor, turbo on).

| Arm (identical code) | median ms | stddev ms | CV |
|---|---|---|---|
| baseline-A | 1107.0 | 36.3 | 3.27% |
| baseline-B | 1111.0 | 30.0 | 2.70% |
| baseline-C | 1102.0 | 25.7 | 2.33% |
| baseline-D | 1128.0 | 31.2 | 2.76% |

**Noise floor = 26 ms range across four identical-code arms, 2.34% of the 1112 ms mean.**
Raw captures in `perf-results/`, summary in `perf-results/noise-floor-coldstart.json`.

**What this licenses:** on this rig, a cold-start change below ~26 ms / 2.3% is
indistinguishable from nothing and must not be claimed as a win. The Phase 1 gate is passed --
the floor is narrow enough to be useful, so the campaign does not need to move to the Pixel 10a
for cold start. Whether the same holds for frame timings under swiftshader is a separate
question and is not yet answered.

**Caveats on the number, stated rather than implied:** `TotalTime` stops at first draw, which
for this app is a mostly-empty tab pager -- it is not time-to-usable-content, and will not be
until `reportFullyDrawn()` lands (Phase 3). The default tab fetches over the network, so some
YouTube variance may sit inside the spread even though first draw likely precedes content.
Host CPU is unpinned, so the floor could probably be narrowed further with `performance` +
`no_turbo=1`; that has not been tested.

### Defects found by running it, not by reading it

Four, each of which would have silently corrupted results:

1. **`init.svc.bootanim` is empty, never `stopped`**, because the emulator boots with
   `androidboot.debug.sf.nobootanimation=1`. Waiting for `stopped` hangs until the timeout.
2. **The shutdown trap killed by serial.** Serials are reused, so a timed-out earlier run
   killed a *newer* emulator that had taken `emulator-5554`. Now gated on the script's own PID.
3. **`adb shell pidof <pkg>` exits 1 when the process is absent** -- the state being waited
   for -- which aborted the script under `set -e` in exactly the success case.
4. **`am force-stop` alone does not guarantee a COLD launch.** Background work respawns the
   process; iterations 6 and 9 came back `WARM`. Fixed with `am start -S`, which force-stops
   atomically with the launch, plus a bounded retry. The strict COLD assertion stays -- mixing
   a warm launch into a cold median measures the wrong workload.

Also corrected: a bounds-parsing bug of my own (`tr -d '[]'` merges `[800,1618][976,1767]`
into `800,1618976,1767`, sending every tap off-screen). Use the sed form upstream uses.

### Phase 2 findings (2026-09-12)

**The seeded-local-playlist workload does not test C1.** `LocalPlaylistFragment` uses
`LocalItemListAdapter` -> `LocalPlaylistStreamItemHolder`, which reads `progressMillis`
pre-joined from `PlaylistStreamEntry` (`PlaylistStreamDAO.getOrderedStreamsOf`). The per-bind
blocking call exists only in `StreamInfoItemHolder.java:102-103,164` and
`StreamMiniInfoItemHolder.java:73-74,133`, both driven by `InfoListAdapter`. Every
`InfoListAdapter` screen is network-fed, and no Room-backed or `androidTest` path constructs
one from canned items. **The app's default tab is a `KioskFragment`, which does use
`InfoListAdapter`** -- so C1 is reachable without seeding, at the cost of non-deterministic
content.

**Compilation state cannot be pinned on a debug build -- at all.** The app is `DEBUGGABLE`, and
ART refuses to AOT-compile a debuggable app past `verify`.
`adb shell cmd package compile -m speed -f wtf.pipepiped.debug` prints `Success`, exits 0, and
leaves `x86_64: [status=verify] [reason=cmdline]` unchanged (`-m speed-profile` likewise). The
harness recorded `"compileMode": "speed"` while running interpreted+JIT. The 26 ms cold-start
noise floor stands -- every arm was equally unpinned -- but the label was false, and the harness
now reads the filter back and refuses to proceed on a mismatch.

This makes the Phase 4 `benchmark` buildType (`initWith(release)`, `debuggable false`) a
**measured requirement**, not a convention: without it there is no way to control or even
truthfully record compilation state.

**C1 is worse than first described.** `HistoryRecordManager.loadStreamState(InfoItem)`
(`:299-313`) ends `.subscribeOn(Schedulers.io())`, and the holder calls `.blockingGet()` on the
main thread. Each bind therefore pays a thread handoff *plus* two Room `Flowable` cycles (each
itself a `blockingFirst()`) while the UI thread parks. `subscribeOn(io)` followed by a blocking
wait is strictly worse than an inline query -- it adds scheduling latency to a block it cannot
avoid.

**Swiftshader hides UI-thread work, and the fix is to change the metric, not the GPU.**
A 15-pair swipe on the kiosk list, 528 unique frames:

| stage | p50 ms |
|---|---|
| gpuSwap | 20.83 |
| sync | 1.28 |
| inputHandling | 0.77 |
| traversalDraw | 0.30 |
| animation | 0.008 |
| frame total | 28.73 |

All UI-thread work is ~1.08 ms of a 28.7 ms frame (3.8%), which would fail the 5% gate. But
`gpuSwap` at 20.8 ms is software rasterization, so that denominator does not exist on real
hardware -- rejecting C1 on it would be rejecting it for a fake reason. This is the **slack**
failure mode from the campaign method.

The correct response is *not* to chase `-gpu host`. `traversalDraw` measures CPU work on the UI
thread and is **independent of the rendering backend**, so it is a valid measurement of C1's
cost even under swiftshader. What is invalid is using emulator end-to-end frame time as the
denominator. So: measure the component on the emulator, compute the ceiling against a real
device's frame budget. `PIPEPIPED_EMU_GPU` exists to quantify how much of `gpuSwap` is
swiftshader, which is worth knowing once, not to become the default.

**Stage medians are the wrong statistic for a per-bind cost.** During a fling most frames bind
no new item, so a per-bind cost cannot appear in a stage median by construction -- it lands in
the tail. `traversalDraw` p99, not p50, is the number that decides C1. (Definitions matter
here: `traversalDraw` = `SyncQueued - PerformTraversalsStart`, which includes draw-list
recording; `uiThreadMs` = `DrawStart - HandleInputStart`, which excludes it and is therefore a
lower bound.)

**Caveat on the 28.7 ms capture:** taken while two other agents were driving the same emulator.
The shape is trustworthy, the magnitudes are not. Superseded by the clean measurement below.

### Scroll baseline, noise floor, and the C1 verdict (2026-09-12, uncontended)

Four identical-code arms, 15 swipe pairs each on the default kiosk tab, ~720 usable frames per
arm, nothing else touching the device. `traversalDraw` = `SyncQueued - PerformTraversalsStart`,
the window containing `onBindViewHolder`:

| arm | frames | p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| A | 721 | 0.296 | 0.760 | 1.075 | 1.469 | 16.12 |
| B | 724 | 0.323 | 0.789 | 1.044 | 1.492 | 15.66 |
| C | 708 | 0.318 | 0.852 | 1.107 | 1.477 | 30.13 |
| D | 717 | 0.299 | 0.735 | 1.062 | 1.413 | 23.80 |

**Noise floor:** frame p50 spans 28.70-29.21 ms (**1.75%**); `traversalDraw` p99 spans 5.4%,
p50 spans 8.7%; deadline jank 2.5-3.3%. Recorded in `perf-results/noise-floor-scroll.json`.

**The earlier tail was contention, not binds.** The contended capture's `traversalDraw` p99 of
3.37 ms and max of 150.5 ms do not reproduce: uncontended p99 is 1.41-1.49 ms. `max` still
swings 15.7-30.1 ms between identical arms, so it is a single outlier frame and not a signal to
build on.

**C1 ceiling, and the verdict.** Granting C1 *all* of `traversalDraw` -- far too generous, since
that stage also contains every measure, layout and draw-recording operation -- removing it
entirely buys 0.31 ms at p50 and 1.47 ms at p99. Against a 16.67 ms budget that is 1.9%
typical; against this rig's 29 ms frame, ~1%. Meanwhile `gpuSwap` p50 is 22 ms. And this is a
debug build running interpreted+JIT, so the Java/RxJava overhead measured here is an **upper**
bound on release.

**C1 was declined on this basis, and the decline was REFUTED the same day.** Kept here because
the reasoning error is the useful part; the verdict below supersedes it.

### C1 CONFIRMED by direct measurement -- the traversalDraw ceiling was invalid

A refuter instrumented `StreamInfoItemHolder.java:102-103` with `System.nanoTime()` around
exactly the call under test, rebuilt, and re-ran the same kiosk scroll. 46 real invocations:

| p50 | p90 | p99 | max | mean |
|---|---|---|---|---|
| 3.66 ms | 6.56 ms | 8.80 ms | 9.40 ms | 4.31 ms |

Every sample logged `thread=main isMainThread=true`. That is **~22% of a 16.67 ms frame at
p50**, against the 1.46 ms ceiling claimed above.

**Why the ceiling argument was wrong.** The default kiosk is "Recommended Lives", a live-stream
grid. Live items have `getDuration() <= 0`, so `updateFromItem`'s `item.getDuration() > 0`
branch -- the only branch reaching the blocking call -- is skipped. 52 of 82 binds in one
sample never executed the line at all, so `traversalDraw` was averaging over frames that mostly
did not run the code it was supposedly bounding.

**CONFIRMED from AOSP/androidx source: the binds run outside the traversal bracket.**
`GapWorker.postFromTraversal()` schedules via `recyclerView.post(this)` -- a plain Handler
message on the main Looper, NOT a Choreographer callback. Handler messages dispatch only after
the current `doFrame()` returns, and `SyncQueued` is stamped inside `CALLBACK_TRAVERSAL`
(`Choreographer.java:1096-1106`, `ThreadedRenderer.java:796,816`). Prefetch binds therefore land
strictly after `SyncQueued`. RecyclerView's own class comment states the intent: "the UI thread
has idle time after it has passed a frame off to RenderThread but before the next frame begins.
We schedule prefetch work in this window."

`traversalDraw` is structurally incapable of bounding per-bind cost. Use a Perfetto trace with a
custom section around `onBindViewHolder`, correlated against the `RV Prefetch` sections
GapWorker already emits.

**The deadline gate does not protect against this call.** `willBindInTime`
(`RecyclerView.java:6829-6832`) tests a **predicted** duration -- an EWMA of past binds for that
view type, pool-wide -- not the actual one, and `tryBindViewHolderByDeadline`
(`:7086-7096`) admits unconditionally when there is no prior sample. Once admitted,
`bindViewHolder()` runs to completion; there is no mid-bind abort. `neededNextFrame` tasks get
`FOREVER_NS` and are forced regardless (`GapWorker.java:357`).

This interacts badly with the live-stream finding: most kiosk items are LIVE_STREAM and skip the
DB call entirely, which drags the shared view type's running average DOWN, which makes the gate
admit exactly the expensive VIDEO_STREAM binds that do hit the database.

Prefetch is on framework defaults throughout the app -- zero `setItemPrefetchEnabled`,
`setItemViewCacheSize` or `setInitialPrefetchItemCount` calls in `app/src/main/java`; both
`SuperScrollLayoutManager` and `GridLayoutManager` (`BaseListFragment.java:216-233`) inherit it.

**Consequence for the rig: this emulator systematically UNDERSTATES prefetch-bind jank.** Frame
p50 is 28.7 ms with `gpuSwap` 22 ms, so the UI thread has a ~22 ms idle window while RenderThread
works, and a 3.66 ms prefetch bind hides in it -- which is why deadline jank measured only
2.5-3.3%. On a real phone with a ~3 ms GPU stage in a 16.67 ms budget that window is a fraction
of the size and the same bind is far likelier to overrun. Swiftshader both inflates the frame
denominator AND inflates the idle gap the work hides in; both make this rig too forgiving for
scroll work. **The C1 fix must be A/B'd on the Pixel 10a, or at minimum under
`PIPEPIPED_EMU_GPU=host`.**

**Why the measured cost is if anything an underestimate:** `streams` held only 500 SoundCloud
rows and `stream_state` was empty while kiosk items are YouTube, so every call short-circuited
after one query (`HistoryRecordManager.java:299-313`). A device with matching watch history runs
the second query too. Counterweight: this is a debug, non-AOT build
(`compilerFilter: run-from-apk`), which inflates the number by an unknown amount -- though the
dominant cost is `subscribeOn(Schedulers.io())` handoff and park/unpark latency, which AOT does
not reclaim.

**Method lesson worth more than the finding:** a stage-level timer was used to bound a
component it did not actually contain. Inference from an aggregate bracket is not a ceiling.
Instrument the component.

### REFUTED: removing `subscribeOn(Schedulers.io())` from C1 (2026-09-12)

**Do not re-propose this as a performance fix.** The mechanism argument is sound and the
measurement killed it anyway.

Pixel 10a, benchmark variant, `compilerFilter=speed`, six **interleaved** arms
(baseline/fixed/baseline/fixed/baseline/fixed), compilation re-pinned after every install:

| | frame p50 | jank vs 8.33 ms budget |
|---|---|---|
| baseline (mean of 3) | 4.456 ms | 5.46% |
| fixed (mean of 3) | 4.547 ms | 5.21% |
| delta | +0.09 ms (worse) | -0.25 pp (better) |
| **noise floor** | **0.114 ms** | **1.10 pp** |

Both deltas sit inside the noise floor. Frame p50 is nominally *worse*. No effect.

**The component really is expensive** -- 2.32 ms p50 / 8.26 ms p99 per call, main thread,
executed on 65 of 132 binds, measured directly on AOT-compiled real hardware and confirmed
independently by a refuter. Both facts are true at once, and the reconciliation is **slack**:
the call runs in RecyclerView's prefetch gap, and at 120 Hz a 4.5 ms median frame leaves
~3.6 ms of idle window that mostly absorbs it. Freeing time that was never on the critical
path buys nothing.

**Reverted** rather than kept, for a second reason specific to this fork:
`HistoryRecordManager.java` is upstream-pristine, so keeping the change would make it the 69th
divergent file and add permanent rebase surface on every future upstream sync, in exchange for
nothing measurable. Diff preserved at `perf-results/refuted/c1-remove-subscribeOn.patch`;
reapply with `git apply` if it is ever wanted on code-quality grounds (it is defensible there --
`subscribeOn` followed by an unconditional `blockingGet` is wrong regardless of speed, and the
**dead, never-called `loadStreamStateBatch`** in the same file suggests someone already knew the
per-bind query was the wrong shape).

**Method note, which is the durable part.** Three times this session a confident mechanism
argument was contradicted by measurement: the traversalDraw ceiling, the C1 decline, and now the
C1 fix. The component-level number was never the question -- the end-to-end delta was. An
expensive component off the critical path is worth exactly zero.

## Decisions taken (2026-09-12)

| Decision | Choice | Why |
|---|---|---|
| Emulator provisioning | **Nix flake** | Reproducible, a fresh clone gets it, matches the project's existing toolchain story. Both derivations already evaluate against the pinned nixpkgs. |
| First metric | **Scroll jank on lists** | The only journey that can be made fully offline and deterministic, so it can become a real regression gate. Also tests the strongest existing hypothesis directly. |
| Build-file structure | **Additive `-PforkBenchmark`-guarded end-of-file block** | Matches the five existing fork blocks at `app/build.gradle:338-429`. Upstream's build stays byte-identical, so benchmark scaffolding costs nothing on an upstream sync. |
| Truth device | **Emulator gates, Pixel 10a confirms** | The emulator is what can be driven unattended; real hardware is what is believed. Every emulator number is labelled as such. |

## Current state

### What already exists (do not rebuild)

This project already has a performance-measurement convention: **emit `MARKER {json}` to
logcat, scrape with a shell script into `.jsonl`, validate with `jq`.** Everything new
follows it.

- `player/PlaybackStartupTrace.java` -- emits `PIPEPIPE_PLAYBACK_STARTUP` JSON via
  `Log.i`, **not** `BuildConfig.DEBUG`-gated, so it survives release builds. Stages
  `detail_click` -> `intent_created` -> `waiting_for_player_service` -> `play_queue_ready`
  -> `player_init_started` -> `resolver_finished` -> `first_frame`.
- `tools/run-youtube-click-to-first-frame.sh` (198 lines) -- drives real UI taps via
  `adb exec-out uiautomator dump /dev/tty` + `sed` bounds extraction + `adb shell input
  tap`. Discovers the APK and application id from `output-metadata.json` (`:38-39`), so it
  already handles the fork's `wtf.pipepiped.debug`. Dismisses this app's startup
  interstitials -- "Enable update checker", "Support the Project", "Announcement",
  "What's New" (`:88-101`). Detects markers race-free by counting logcat matches before
  and after the tap (`:148-164`).
- `tools/run-youtube-playback-benchmark.sh` + `YoutubePlaybackBenchmarkTest.java` --
  playback quality: `resolveMs`, `readyMs`, `firstFrameMs`, rebuffer count/ms, dropped
  frames, `peakPssKb`, `cpuMs`, byte counts, p50/p95.

All of it is upstream (`InfinityLoop1308`), none fork-local.

### What is missing

- **No cold-start timing**, no frame/jank timing, no list-bind cost.
- **No `android.os.Trace` / `androidx.tracing` anywhere** in the app module, so a Perfetto
  trace today shows zero app-level spans.
- **No `reportFullyDrawn()`** anywhere, so time-to-full-display is unmeasurable.
- **No `androidx.profileinstaller`**, so baseline profiles cannot be installed.
- **No CI runs any test.** `ci.yml` runs `assembleDebug lintDebug` only; `release.yml`
  runs no test task. The 112 unit tests and the whole `androidTest` suite execute nowhere
  in the pipeline.
- **Both existing benchmarks require live YouTube**, so their variance includes a remote
  service. Fine for a manual before/after; unusable as a regression gate.

### Known environment

| Thing | State |
|---|---|
| KVM | `/dev/kvm` present, mode `crw-rw-rw-`, no group membership needed |
| CPU | Intel Core Ultra X7 358H, 16 cores, hybrid P/E, governor `powersave`, turbo on |
| RAM / disk | 30 GB total, 195 GB free on `/` |
| `adb` | 1.0.41 / 37.0.1 at `/usr/bin/adb` (Arch `android-tools`) |
| `emulator` | absent; no AVDs, no system images |
| `/opt/android-sdk` | root-owned, Arch-packaged, **not used by the build** |
| Build SDK | `flake.nix:42-49`, `androidenv.composeAndroidPackages`, `includeEmulator = false` |

## Phase 0 -- the rig

No app code touched.

1. **Emulator in `flake.nix`** as a *separate* `composeAndroidPackages` call, so the
   existing build closure is untouched:
   `includeEmulator = true; emulatorVersion = "36.6.9"; includeSystemImages = true;
   systemImageTypes = [ "google_apis" ]; abiVersions = [ "x86_64" ];`
   Exposed as `nix run .#emulator`. Verified to evaluate:
   `android-sdk-emulator-36.6.9.drv`.
   - `google_apis`, **not** `google_apis_playstore` -- Play images are `user` builds that
     refuse `adb root`, which perfetto capture needs.
   - x86_64 because `:ffmpeg` ships prebuilt native libs for `arm64-v8a` and `x86_64`
     only, and the click script reads `getprop ro.product.cpu.abi`.
2. **Pinned AVD** `bench_api36`: 4 cores, 4096 MB, `hw.gpu.mode=swiftshader_indirect`.
   Launched `-no-window -gpu swiftshader_indirect -no-snapshot -wipe-data -no-audio
   -no-boot-anim`.
   - `swiftshader_indirect` over `host` deliberately: it removes the laptop's GPU driver,
     compositor and thermal behaviour from every number. Absolute frame numbers on an
     emulator are meaningless anyway, so buy determinism instead.
   - **Snapshots are the single biggest source of fake deltas** -- a restored snapshot
     carries warm page cache, a populated ART profile, and whatever `/data` the last run
     left. Always `-no-snapshot -wipe-data`.
3. **Boot script** with the full readiness idiom, since `adb wait-for-device` returns long
   before the system is usable:
   `sys.boot_completed == 1`, then `pm path android` answers, then
   `init.svc.bootanim == stopped`. Wrapped in a `timeout` so a wedged emulator fails the
   run instead of hanging it.
   Then, **re-applied after every boot** because `-wipe-data` reverts them:
   the three animation scales to `0.0`, `cmd package bg-dexopt-job --disable`,
   `dumpsys deviceidle disable`, `svc power stayon true`, `auto_time 0`.
4. **Host pinning**: `performance` governor and `no_turbo=1` (both need sudo -- ask
   before running), emulator kept off the E-cores, and no Gradle build running during a
   measurement.

## Phase 1 -- baseline and noise floor

**Still zero code changes.** Against the current debug APK, using only `adb` primitives.

- `am start -W -S` x15 after `cmd package compile -m speed -f`, reporting **median and
  spread**, never a bare mean. Treat `TotalTime` as a local sanity check, not a release
  metric: it stops at first draw, not at usable content, and includes a few hundred ms
  nobody can influence.
- `dumpsys gfxinfo <pkg> framestats` across a scripted fixed scroll.
  - **Parse the header row the device actually emits.** The column count is
    platform-dependent (23 on current Android, not the 16 older posts list) and every row
    carries a trailing comma.
  - Skip rows where `Flags != 0` -- those had a layout change and some timestamps are
    garbage. For the rest, `frame_duration = FrameCompleted - IntendedVsync`; read the
    budget from `FrameInterval` rather than assuming 16.67 ms.
  - **The buffer holds only the last 120 frames** (2 s at 60 Hz). Poll at least every
    1.5 s and append, then dedupe on identical timestamps.
- **The control test, which is the actual deliverable of this phase**: two captures of
  identical, unchanged code. Their delta *is* the noise floor. Any later "win" smaller
  than it is indistinguishable from nothing.
- Captures persist to a gitignored `perf-results/<date>-<variable>/`, never `/tmp`.

**Gate:** if the noise floor is wider than the effects worth chasing, say so plainly and
move measurement to the Pixel 10a. Do not proceed to Phase 3 on an unusable floor.

## Phase 2 -- deterministic workloads

| Workload | Determinism |
|---|---|
| Cold start to `MainActivity` | Tabs configured local-only, so no network on the first frame |
| **Scroll a seeded 500-item local playlist** | Prepared Room DB pushed to the device so the list is byte-identical every run; DeArrow toggled off to remove the network |
| Click to first frame | Upstream's script unchanged, run separately, numbers labelled network-bound |

The scroll workload is chosen because it exercises the `blockingGet()` path directly.

Two defects in the existing click script to fix if it is reused as a gate:
- Rounds do `am force-stop` but never `pm clear` (`:114`), so round 0 has an empty cache
  and rounds 1-4 do not. One p50 over both is a p50 over two different workloads.
- `am start -W` output is `tee`'d to the log (`:115-116`) but `TotalTime` never reaches
  the `.jsonl` -- measured, then discarded.

Fork wrinkle: the scripts default `OUTPUT` to `../log/...`, resolved from
`PipePipeClient/`. On the meta-repo layout that writes into the meta repo root, which
`PipePipeClient/.gitignore:14` ignores but the meta `.gitignore` does not. Upstream never
hits this because they clone the client standalone.

## Phase 3 -- instrumentation (the app code changes)

All additive. None in files the concurrent Phase 12 work is editing.

1. `androidx.tracing:tracing:1.3.0` (`tracing-ktx` is redundant at 1.3.0), with
   `trace("PipePipe.X") { }` sections around: `App.onCreate` stages, `MainActivity.onCreate`,
   `onBindViewHolder`, `loadStreamState`, Picasso `into()`, DeArrow `apply`.
   **Labels must stay under 127 chars** (`MAX_TRACE_LABEL_LENGTH`) -- longer ones are
   truncated, which silently breaks exact-match `TraceSectionMetric` lookups.
2. `Trace.forceEnableAppTracing()` early in `App.onCreate`, so sections are captured in
   non-debuggable builds.
3. `<profileable android:shell="true" tools:targetApi="29" />` in the app manifest.
4. **`reportFullyDrawn()`** at first-tab-content-ready. Without it `timeToFullDisplayMs`
   is *absent* from the benchmark JSON -- not zero, not null, absent -- and "first frame"
   for this app is an empty tab pager.
5. `androidx.profileinstaller:profileinstaller:1.4.1` in the app module (Macrobenchmark
   needs 1.3+ for profile capture/reset and shader-cache clearing).
6. **Debug-only StrictMode `detectAll().penaltyLog()`** replacing the current
   `permitAll()` at `MainActivity.java:138-140`. Nearly free, and it enumerates
   main-thread I/O on its own. Today that call actively silences the signal.
7. A cold-start stage trace class following `PlaybackStartupTrace`'s convention exactly.

## Phase 4 -- Macrobenchmark module

`:macrobenchmark`, `com.android.test`, `minSdk = 24`.

- **`androidx.benchmark:1.5.0`, not 1.4.1.** Verified from the published plugin jar:
  1.5.0 has `MIN_AGP_VERSION_REQUIRED_INCLUSIVE = 8.0.0` and
  `MAX_AGP_VERSION_RECOMMENDED_EXCLUSIVE = 10.0.0-alpha01`, so AGP 9.2.1 is inside the
  window. 1.4.1 caps at `9.0.0-alpha01` and would warn.
- `minSdk = 24` is forced by `benchmark-macro-1.5.0.aar`'s own manifest. The app is
  `minSdk 23`. It is a test-only module so the shipped app is unaffected -- but the
  benchmark suite therefore cannot measure the app's actual minimum API.
- `androidx.benchmark.suppressErrors=EMULATOR`. Running on an emulator is a suppressible
  *error*, not a refusal; Google explicitly discourages it.
- `CompilationMode.None()` and `.Full()` as **separate tests**. They bracket the true
  effect, and agreement between them is strong evidence a change is real. `Full()` has the
  lowest variance, which matters most on an emulator where variance is the binding
  constraint. Never compare across modes.
- The `benchmark` buildType goes in the fork's additive end-of-file block guarded by
  `project.hasProperty('forkBenchmark')`, matching `app/build.gradle:338-429`.

### JSON parsing traps

Output lands at
`macrobenchmark/build/outputs/connected_android_test_additional_output/benchmarkAndroidTest/connected/<device>/<pkg>-benchmarkData.json`.

- **`metrics` vs `sampledMetrics` are different maps.** `StartupTimingMetric` lands in
  `metrics`; `FrameTimingMetric`'s `frameOverrunMs` lands in `sampledMetrics`. A parser
  reading only `.metrics` silently drops every frame number.
- Percentile keys are `P50`/`P90`/`P95`/`P99` -- capital P, no lowercase variant.
- `coefficientOfVariation` is already computed per metric. Use it as the variance gate.
- `timeToFullDisplayMs` is absent until item 4 of Phase 3 lands.
- The `context` block records `cpuLocked`, `cpuMaxFreqHz` and `compilationMode`, so each
  capture self-documents whether the machine was pinned.
- On emulator prefer `frameDurationCpuMs` over `frameOverrunMs`: the latter needs API 31+
  and the SurfaceFlinger frametimeline, which is synthetic under swiftshader.
- **If no JSON appears at all when driving `am instrument` by hand**, set
  `androidx.benchmark.output.enable=true` explicitly. It is a real argument but is not on
  Google's instrumentation-args page; when unset the library logs
  "not writing results json" and writes nothing.

### If driving Perfetto directly rather than via Macrobenchmark

`atrace_apps: "<package>"` in the config is **mandatory**. Without it the trace contains
kernel events and no app slices, and every `androidx.tracing` section from Phase 3 is
simply absent. This is the most common way custom sections "silently do not work".

## Phase 5 -- the campaign loop, per candidate

1. Identify which resource binds. **Refute it with a scaling test**: if the claim is
   "bound by X", halving X's work should move the metric near-proportionally. If it does
   not, the claim is dead whatever the utilization numbers said.
2. Compute the ceiling assuming a *perfect* fix:
   `ceiling = metric_now - metric_with_component_at_zero_cost`.
   **Refute that too**, hunting double-counting and slack -- a component whose cost is
   already hidden behind a wait contributes zero however large it looks in a profile.
3. **Gate: ceiling under 5% of the metric, or under the Phase 1 noise floor -> do not
   build it.** Record as measured-and-declined and move to the next candidate.
4. One change. Not two.
5. Interleaved A/B (A B A B, never all-A-then-all-B), N >= 5 per arm, same workload
   content.
6. Verdict: keep only a win that survives an independent re-run. No measured effect ->
   revert, and record the refutation so it is not re-proposed.

### Candidate queue

**C1 -- hypothesis, not a finding.** A blocking Room query on every bind:

```java
// info_list/holder/StreamInfoItemHolder.java:102-103
final StreamStateEntity state = historyRecordManager.loadStreamState(infoItem)
        .blockingGet()[0];
```

Also at `StreamInfoItemHolder.java:164` and `info_list/ComposeItemUiHelper.kt:245`. Runs on
search, channel, playlist and related-video lists. The Feed screen is exempt -- it
pre-joins progress via `streamWithState.stateProgressMillis`. It looks obviously bad, which
is exactly why it gets a measured ceiling before anyone edits it.

**C2.** `InfoListAdapter` and `LocalItemListAdapter` call `notifyDataSetChanged()`
unconditionally on `setInfoItemList` / `addItems` / `sort` / `filter` -- a full rebind with
no DiffUtil. `FeedFragment` already uses `groupAdapter.updateAsync`.

**C3.** `App.onCreate` runs an `AndroidWebViewAvailabilityChecker.warmUp()` on the main
thread (`App.java:133-136`), alongside Picasso OkHttp + disk-cache construction
(`:151-157`) and the DeArrow disk-cache open (`:161`).

**C4.** `ComposeInfoItemHolder` calls `setContent {}` fresh on every bind with no diffing,
and `resolveComposeColorScheme` reads SharedPreferences per composition
(`ComposeItemUiHelper.kt:104-113`).

## Risks and open questions

- **The emulator may not be good enough.** Swiftshader frame timings are synthetic. Phase 1
  exists to find this out before Phase 3 is written, not after.
- **Unverified, carried forward honestly**: Gradle 9.5.1 against benchmark 1.5.0 has no
  explicit statement either way in the release notes; `emulator -cores` and `-read-only`
  are absent from the official command-line page; the `skipBenchmarksOnEmulator` default is
  unknown, so set it explicitly or macrobenchmarks may silently skip.
- **Not yet decided**: whether CI should run any of this. Today no workflow runs a single
  test, so wiring `:app:testDebugUnitTest` into `ci.yml` is a separate, cheaper win worth
  proposing on its own.

## Out of scope, flagged not fixed

`MainActivity.trustEveryone()` (`MainActivity.java:940`) installs a global
`HostnameVerifier` returning `true` and an `X509TrustManager` with an empty
`checkServerTrusted`, then sets both as the process-wide `HttpsURLConnection` defaults --
disabling TLS certificate and hostname validation. It is upstream code, unrelated to
performance, and needs its own decision.
