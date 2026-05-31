# Project: PipePipe+ — DeArrow support & signed release fork

> Last updated: 2026-05-31 | Session: 6

## Overview
Maintain a personal fork of **PipePipe** (a NewPipe-based Android client) that adds **DeArrow** support — crowdsourced de-clickbait **titles + thumbnails** for YouTube — while tracking upstream `InfinityLoop1308/PipePipe`. The PipePipe repo is a thin meta-repo; real code lives in submodules (`PipePipeClient` = the app, `PipePipeExtractor` = the extractor lib). Strategy: **fork only what we modify** — only `PipePipeClient` is forked (to `HritwikSinghal/PipePipeClient`) and carries a `patch` branch; the extractor stays upstream-pinned/dormant. The meta-repo's `patch` branch repoints the client submodule at our fork and is the **default branch** on origin. End state: `git fetch upstream` + rebase keeps us current, `nix run .#build` produces a signed **PipePipe+** APK (distinct `applicationId`, installs alongside the official app), and a `workflow_dispatch` GitHub Actions release publishes a signed APK (keystore via GitHub Secrets) — mirroring `~/Projects/reddit/continuum`.

## Current State (verified from repo, 2026-05-31, Session 4)
- **Meta-repo** `patch` = **2 commits** atop upstream `989e9fd` (v5.1.1): `build:` (Nix flake + submodule wiring, gitlink) + `docs:` (this tracker + design). Pushed. `main` = clean upstream mirror. Default branch on origin = **`patch`**. Remotes: `origin`=`HritwikSinghal/PipePipe`, `upstream`=`InfinityLoop1308/PipePipe`.
- **Submodule pins** (meta `patch` tree): `PipePipeClient` @ `51cd432d5` (our fork, branch `patch`), `PipePipeExtractor` @ `871ea2d` (upstream, dormant), `PipePipe.wiki` @ `40f284d` (never initialized). `.gitmodules`: client → fork `patch`; extractor + wiki → upstream.
- **PipePipeClient** `patch` = **1 squashed commit `51cd432d5`** ("feat(dearrow): client-side title de-clickbait support") atop upstream `188c64eb9`. Pushed, clean. Holds all of Phase 3 (service) + Phase 4 units A (settings) + B (list titles). Remotes: `origin`=fork, `upstream`=`InfinityLoop1308`. Default branch on fork = `patch`.
- **PipePipeExtractor**: detached @ `871ea2d`, upstream-only, **dormant** (DeArrow is client-only; its fork was deleted Session 3 — no unique work).
- **Backups:** `backup/pre-squash-s4` exists in both repos (pre-squash tips); client also has `patch-prerebase-s3` (pre Session-3 upstream rebase). Safe to delete once the squashed history is confirmed good.
- **Not yet built/run:** baseline `nix run .#build` (deferred by user) and the gradle unit-test run — both gated on first running the Nix toolchain.

## Next Session Pickup (START HERE)

**Status:** **Phase 1 build now WORKS** — `nix run .#build` → BUILD SUCCESSFUL, 5 debug APKs (Session 6; required a JDK swap, see Session 6 note). Phase 3 done. Phase 4 units **A (settings)** + **B (recycled list holders)** committed & pushed (`51cd432d5`). Unit **C (non-recycled title sites)** is **implemented in the working tree and now COMPILE-VERIFIED** (the Session-6 build compiled it clean) but **NOT yet committed**. **Next = remaining Phase 4 items: "show original titles" behavior, manual device/emulator verification, then commit & push on client `patch` + bump the meta gitlink. Two uncommitted changes await a commit decision: the client Unit-C edits (on client `patch`) and the `flake.nix` JDK fix (on meta `patch`).**

**Unit C — what Session 5 changed (uncommitted, in `PipePipeClient` working tree):**
- `DeArrowTitleApplier`: added `dispose()` (for transient sites) + a `url != null` gate (closes a latent NPE — `getId(null)` throws `NullPointerException`, which `apply()`'s catch did not cover).
- `VideoDetailFragment.java`: applier field + `apply(detailVideoTitleView, serviceId, url)` at both `showLoading()` (~:1810) and `handleResult()` (~:1842). TextView-only, `title` field untouched. [OK]
- `Player.java`: applier field + `apply(titleTextView, info.getServiceId(), info.getUrl())` at `onMetadataChanged` (~:3536).
- `InfoItemDialog.java`: local applier + `apply` after the title set (:60); disposed via `dialog.setOnDismissListener(... dispose())` (transient view — avoids retaining a dismissed dialog).
- `PlayQueueActivity.java`: applier field + `apply(songName, ...)` in `onMetadataUpdate` (~:494) — the now-playing title.
- **`PlayQueueItemHolder` + `PlayQueueItemBuilder`**: per-holder applier field; `apply` in `buildStreamInfoItem` (recycled — extra site beyond §4, included per user decision Session 5).

Re-read `docs/dearrow-design.md` §3.4–§3.5 (recycled-async pattern) and §4 (hook sites) if revisiting.

**What's implemented (reusable building blocks, all under `app/.../util/dearrow/`):**
- `DeArrowService.getInstance().getBranding(videoId)` → `Maybe<DeArrowBranding>` (RxJava3; hash-bucket cache, dedup; never errors to UI; empty == keep original).
- `DeArrowTitleFormatter.selectTitle(branding, autoFormat)` → replacement `String` or `null`.
- `DeArrowSettings.isTitleReplacementEnabled(ctx)` / `isAutoFormatTitlesEnabled(ctx)` / `isEnabled(ctx)`.
- **`DeArrowTitleApplier`** — `apply(TextView titleView, int serviceId, String url)`. Encapsulates the per-site mutable bound-id + `Disposable`; does dispose-on-rebind, the YouTube/pref gate, the video-ID parse, and the stale-result guard. **Reuse this for unit C** (one instance per view site). Already wired into the recycled holders `StreamInfoItemHolder` + `StreamMiniInfoItemHolder`.
- YouTube gate: `serviceId == ServiceList.YouTube.getServiceId()`. Video-ID: `YoutubeStreamLinkHandlerFactory.getInstance().getId(url)` — **throws `ParsingException` AND unchecked `IllegalArgumentException`** on bad URLs; `DeArrowTitleApplier` already multi-catches both.

**Unit C — non-recycled title sites** (give each its own `DeArrowTitleApplier` instance; the applier already disposes the prior fetch on each call):
- `fragments/detail/VideoDetailFragment.java:1808` & `:1840` (`binding.detailVideoTitleView.setText(title)`) — **override the TextView ONLY; never reassign the `title` field** (set at :1690; used by share/notification/history).
- `player/Player.java:3535` (`binding.titleTextView.setText(info.getName())`).
- `info_list/dialog/InfoItemDialog.java:59` (`titleView.setText(info.getName())`).
- `player/PlayQueueActivity.java` queue-item title — design said ~:492 but **NOT confirmed** (only the action-bar title at :81 surfaced). **Rediscover** the queue-item bind site (likely a `PlayQueueItemBuilder`/holder) before editing.
- Line numbers were current at the pre-squash client; the squash changes no content, but always re-grep before editing.

**Then close Phase 4:** manual device/emulator verification → commit on client `patch` → bump the meta `PipePipeClient` gitlink to the new client HEAD and commit the meta. **Push ordering for gitlink bumps: push the client `patch` BEFORE the meta `patch`**, else a recursive clone can't resolve the gitlink in the window between.

**Gotchas:**
- Checkstyle runs over `src/main` + `src/test` (not in `assembleDebug`): 100-col, `final` params/locals/for-vars, no unused imports, no trailing whitespace, trailing newline. Hand-check new files (`grep -nE '.{101,}'`).
- An emoji PostToolUse hook blocks edits to files containing emoji (e.g. a pre-existing donation string in `strings.xml`). The edit still APPLIES; ignore for pre-existing emoji, but don't introduce new ones (use `[X]`/`CAUTION:` etc.).
- `getBranding` is a `Maybe` — use 2-arg `subscribe(onSuccess, onError)` for RxJava lint.

**Fresh-clone setup (if not in this workspace):**
1. `git clone --recursive git@github.com:HritwikSinghal/PipePipe.git && cd PipePipe && git checkout patch && git submodule update --init` — client lands at gitlink `51cd432d5` (the DeArrow work, pushed). Extractor stays upstream/dormant.
2. Optional (work on a branch, not detached): `cd PipePipeClient && git checkout patch`.
3. Build (first run ~10–40 min, still un-run): from meta root `nix run .#build`. Unit tests: `cd PipePipeClient && nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.*'` (expect `DeArrowTitleFormatterTest` 16 + `DeArrowResponseParserTest` 7 green).

## Plan

### Phase 1: Foundation — Nix toolchain, branching model & submodule wiring
- [x] Fix malformed `upstream` remote URL (now `https://github.com/InfinityLoop1308/PipePipe.git`)
- [x] Initialize & check out submodules (client + extractor upstream-pinned)
- [x] Inspect PipePipeClient build — composite build (`includeBuild('../PipePipeExtractor')`); AGP 7.3.0 / Gradle 7.5 / Kotlin 1.7.20; compileSdk 33, Java 11; prebuilt `ffmpeg-kit.aar` (no NDK); existing `packageSuffix` release hook
- [x] Write `flake.nix` — Android SDK 33 + build-tools 30.0.3/33.0.1 + JDK 11 + aapt2 override + dev shell + `.#build` app; `nix eval`-validated
- [x] Baseline build under Nix (`nix run .#build`) — **BUILD SUCCESSFUL, 5 debug APKs** (Session 6). Built *with* the uncommitted Phase-4 Unit-C edits, so it also compile-verified that code. Required swapping the JDK to prebuilt Temurin (see Session 6 note).
- [x] PipePipeClient fork wired (`origin`=fork, `upstream`=InfinityLoop1308); `patch` branch created & pushed
- [x] Meta `patch` branch off `main`; `.gitmodules` cleaned + repointed to fork; foundation committed & pushed

### Phase 2: Map SponsorBlock & design DeArrow integration
- [x] Trace SponsorBlock (extractor-side `SponsorBlockExtractorHelper`; settings template = `sponsor_block_settings.xml` + keys + fragment + registry/`main_settings`)
- [x] Identify title/thumbnail render sites + image loader (**Picasso** via `PicassoHelper`); models immutable → replace at view layer (mapped in `docs/dearrow-design.md` §4)
- [x] Research DeArrow API (branding `…/api/branding/<hashPrefix>`, thumbnail generator; GPL-3.0 + attribution required)
- [x] Write `docs/dearrow-design.md` blueprint

### Phase 3: DeArrow service in the Client  *(revised — was "in the Extractor")*
- [x] `DeArrowService` singleton: `Maybe<DeArrowBranding> getBranding(videoId)` via hashPrefix bucket over `NewPipe.getDownloader()` (RxJava3, `Schedulers.io()`)
- [x] POJOs (`DeArrowBranding`/`DeArrowTitle`/`DeArrowThumbnail`) + pure `DeArrowResponseParser` (nanojson)
- [x] Hash-bucket `LruCache` (positive+negative, 6h TTL) + per-prefix in-flight dedup; graceful empty-on-error
- [x] `DeArrowTitleFormatter` (pure) + unit tests (16 cases) — **executed green standalone** (java-17 + cached JUnit)
- [x] No extractor changes; committed & pushed on client `patch`

### Phase 4: DeArrow titles in the Client
- [x] DeArrow settings (master/titles/auto-format toggles) mirroring SponsorBlock prefs + `DeArrowSettings` reader (unit A)
- [x] Wire replacement-title fetch + apply into recycled list holders via `DeArrowTitleApplier` (unit B)
- [x] Wire the non-recycled title sites (detail/player/dialog/queue) — unit C *(also covered the recycled play-queue list, see Decisions; implemented & review-checked, NOT yet compiled/committed)*
- [ ] Respect existing "show original titles" behavior; add per-item indicator if appropriate
- [ ] Manual verification on device/emulator
- [ ] Commit & push on client `patch`; bump pinned SHA in meta `patch`

### Phase 5: DeArrow thumbnails in the Client
- [ ] Integrate DeArrow thumbnail source with Picasso
- [ ] Add thumbnails settings toggle; fallback to original on miss/error
- [ ] Cache thumbnails; verify across feed/search/video-info
- [ ] Commit & push on client `patch`; bump pinned SHA in meta `patch`

### Phase 6: Build config — versioning, identity, signing, `nix run .#build`
- [ ] Add `forkBaseVersionCode`/`forkBaseVersionName` + CI-injected `-PforkVersion*` to client `build.gradle`
- [ ] `keystore.properties` → `signingConfigs.release`; `applicationIdSuffix` (PipePipe+) + app_name "PipePipe+"
- [ ] Generate release keystore; add `KEYSTORE_BASE64` + passwords/alias as GitHub Secrets
- [ ] Extend `flake.nix` `.#build` to build + sign + emit APK (gitignored local keystore; CI uses Secrets)
- [ ] Verify `nix run .#build` produces a signed PipePipe+ APK locally
- [ ] Commit build changes on client `patch`; bump pinned SHA in meta `patch`

### Phase 7: Release workflow on `patch` & default branch
- [ ] Add `.github/workflows/release.yml` (workflow_dispatch, recursive submodule checkout, decode keystore, build signed APK, gh-release)
- [ ] Adapt version computation; skip `lintVitalRelease` if it blocks fresh builds
- [x] Set `patch` as the default branch on origin (done Session 3, early — `workflow_dispatch` UI needs the workflow on the default branch)
- [ ] Trigger a test release run; confirm signed APK published
- [ ] Verify APK installs alongside official PipePipe

### Phase 8: Upstream-sync maintenance & docs
- [ ] Document/script the sync flow: rebase meta `patch` on upstream `main`; rebase submodule `patch` on its upstream; re-pin SHAs
- [ ] Add maintenance notes to README/CLAUDE.md
- [ ] Optional: scheduled CI to detect upstream updates
- [ ] Final end-to-end verification (build + install) and wrap-up

## Status Summary
| Phase | Status | Progress |
|-------|--------|----------|
| Phase 1: Foundation — Nix toolchain, branching & submodule wiring | Done | 7/7 |
| Phase 2: Map SponsorBlock & design DeArrow | Done | 4/4 |
| Phase 3: DeArrow service in the Client | Done (gradle test run pending) | 5/5 |
| Phase 4: DeArrow titles in Client | In Progress | 3/6 |
| Phase 5: DeArrow thumbnails in Client | Pending | 0/4 |
| Phase 6: Build config — versioning, identity, signing, nix build | Pending | 0/6 |
| Phase 7: Release workflow & default branch | Pending (default-branch done early) | 1/5 |
| Phase 8: Upstream-sync maintenance & docs | Pending | 0/4 |

## Decisions & Notes
- **Branching model:** track upstream `main`; our work lives on `patch` in the meta-repo and the client fork. **Fork only what we modify** — only `PipePipeClient` is forked; the extractor stays upstream-pinned/dormant (its fork was deleted, no unique work); `PipePipe.wiki` is never forked/initialized. `patch` is the default branch on both the meta fork and the client fork.
- **DeArrow = client-only, display-time.** Unlike SponsorBlock (extractor-side, player-time, single video), DeArrow de-clickbaits **list items** before you click, so it's a view-layer decoration — resolve a replacement at render time, fall back to the original on any miss. The only extractor dependency is `YoutubeStreamLinkHandlerFactory.getId()` (public API). Scope = **titles + thumbnails** behind toggles, across all YouTube surfaces (lists/detail/player/queue/dialog); local-DB history deferrable.
- **Stack facts:** client uses **RxJava3**, JSON via **nanojson**, images via **Picasso** (its own OkHttp; fetches thumbnails directly — the extractor `Downloader` is text-only). **Never mutate immutable extractor models**, and **never overwrite `VideoDetailFragment.title`** (used by share/notification/history) — replace at the view layer only.
- **Build toolchain = the project's own:** AGP 7.3.0, Gradle 7.5, Kotlin 1.7.20, compileSdk/targetSdk 33, minSdk 21, Java 11. → flake pins **JDK 11** (Gradle 7.5/AGP 7.3 are incompatible with JDK 21) + platform 33 + build-tools 30.0.3 & 33.0.1 + aapt2 override; **no NDK** (the `:ffmpeg` module ships a prebuilt `ffmpeg-kit.aar`). Build runs inside `PipePipeClient/` via its own `./gradlew` (composite-includes `../PipePipeExtractor`). `nix run .#build` currently builds a **debug** APK; Phase 6 switches it to a signed **release** build.
- **Signing / identity:** keystore via **GitHub Secrets** (repo is public — keystore never committed; local signing uses a gitignored auto-generated keystore). App name **"PipePipe+"**, distinct `applicationId` (suffix TBD Phase 6). Release pattern mirrors `~/Projects/reddit/continuum/.github/workflows/release.yml`.
- **Phase 3 verification status:** the POJOs + `DeArrowTitleFormatter` are pure (zero Android/RxJava/nanojson deps) and the formatter's 16 unit tests ran **green standalone**. `DeArrowService` (Android `LruCache` + RxJava3) and the nanojson parser test are verified by review only until the Nix gradle build runs `:app:testDebugUnitTest`.
- **2026-05-31 (Session 5) — flake hardened against JDK 11 daemon crash.** The first real `nix run .#build` crashed the Gradle daemon JVM (SIGSEGV in `ObjectSynchronizer::inflate`, null deref, from a C2-compiled `monitorenter`) under Gradle's 80-thread concurrent dependency download on the Manjaro host. Root cause = OpenJDK 11 biased-locking race (deprecated/removed in later JDKs via JEP 374), not our code or build config. Fix: added a shared `extraJavaToolOptions = "-XX:-UseBiasedLocking"` and exported it via `JAVA_TOOL_OPTIONS` (inherited by the forked daemon JVM; `GRADLE_OPTS` only reaches the client JVM) in both `mkBuildApp` and `mkDevShell`. Mitigation not yet confirmed by a successful build. Fallback if it recurs: add `-XX:TieredStopAtLevel=1`, then try a non-Nixpkgs JDK 11 (e.g. Temurin).
- **2026-05-31 (Session 6) — build FIXED; Session-5 diagnosis corrected.** The `-XX:-UseBiasedLocking` mitigation **did not work** — `nix run .#build` crashed again (`hs_err_pid398492` + `400603`, both with the flag confirmed active, `UseBiasedLocking = false`). Reproduced **3/3**, every crash a null deref (`si_addr=0x0`) *inside* `ObjectSynchronizer::inflate(...)+0x320`. The callers differed — interpreter (`InterpreterRuntime::monitorenter`) **and** C1 (`Runtime1::monitorenter`) — so it was **not** "a C2-compiled monitorenter" and **not** biased locking; the fault is in `inflate` itself. **Real root cause:** nixpkgs-unstable's `jdk11` is **source-built with gcc 15.2.0** (per the crash header), which miscompiles OpenJDK 11's HotSpot lock code; no JVM flag or Gradle setting can fix a miscompiled binary. **Fix:** flake now uses the **prebuilt `pkgs.temurin-bin-11`** (11.0.31, vendor binary built with an OpenJDK-11-era toolchain); removed the dead `extraJavaToolOptions`/`JAVA_TOOL_OPTIONS` plumbing. **Verified:** changing *only* the JDK → BUILD SUCCESSFUL in 6m48s, then `nix run .#build` end-to-end → 5 APKs (`app/build/outputs/apk/debug/PipePipe_5.1.1-{arm64-v8a,armeabi-v7a,x86,x86_64,universal}-debug.apk`). **`flake.nix` change is uncommitted on meta `patch`.** Observed upstream `applicationId` = `InfinityLoop1309.NewPipeEnhanced` (debug suffix `.debug`) — note for the Phase-6 PipePipe+ distinct id.
- **2026-05-31 (Session 5) — unit C + 2 deviations.** (1) **Recycled play-queue list included:** the queue surfaces titles in *two* places — the non-recycled now-playing title (`PlayQueueActivity.onMetadataUpdate`, the documented §4 ":492" site) AND a *recycled* queue list (`PlayQueueItemBuilder`/`PlayQueueItemHolder`, not in the §4 titles table). Per user decision, included the recycled list too (per-holder applier, unit-B pattern) so the queue matches the de-clickbaited feed. (2) **Null-URL hardening:** added `url != null` to `DeArrowTitleApplier.apply()`'s gate — `YoutubeStreamLinkHandlerFactory.getId(null)` throws an *unchecked* `NullPointerException` (via `new URI(null)`), which the existing `catch (ParsingException | IllegalArgumentException)` did not cover; `VideoDetailFragment.url` is `@Nullable`, so this was a latent crash. Also added `DeArrowTitleApplier.dispose()` for transient sites (wired to the dialog's dismiss). **All review-level only — not yet compiled (Nix gradle build still un-run) or committed.**
- **2026-05-31 (Session 4) — history squashed.** Client: 3 DeArrow commits → 1 (`51cd432d5`). Meta: 8 commits → 2 (build + docs). Both force-pushed; `backup/pre-squash-s4` kept in each repo. Pre-squash content verified byte-identical to the squashed result.

## Blockers
- None.

## Deferred / To verify
- **Baseline build** (`nix run .#build`) — **RESOLVED Session 6.** BUILD SUCCESSFUL, 5 debug APKs. The Session-5 biased-locking theory was wrong; real cause was the gcc-15-miscompiled source JDK, fixed by switching to prebuilt Temurin (see Session 6 note). Leftover crash artifacts `PipePipeClient/hs_err_pid{398492,400603}.log` are now-resolved evidence and can be deleted.
- **Phase 3 gradle verification** — inside `nix develop`: `cd PipePipeClient && ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.*'` (expect `DeArrowTitleFormatterTest` 16 + `DeArrowResponseParserTest` 7 green). Confirms the nanojson parser + that the service compiles in the full Android classpath.
