# Project: PipePipe+ — DeArrow support & signed release fork

> Last updated: 2026-05-31 | Session: 8

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

**Status (Session 8 update):** **Phase 5 is now CODE-COMPLETE (6/7)** — DeArrow thumbnails + the always-present interactive toggle badge are implemented (unified `DeArrowItemController`), recomposed into 3 logical commits (`a860ce2a4..754992090`) and force-pushed to `origin/patch`; dearrow unit tests 40/40. The only open Phase-5 item is on-device verification (gated on Phase 6/7), and a clean full `nix run .#build` was NOT re-run this session (per-task `assembleDebug` + unit tests all passed). **Next = Phase 6 (signing/identity) + Phase 7 (release workflow)** to enable the on-device check. --- _Prior status:_ **Phase 1 build WORKS** (`nix run .#build` → 5 debug APKs; Session 6 JDK swap). **Phase 4 is code-complete (5/6)** — units A/B/C + the new "Mark replaced titles" indicator are all committed & pushed (client `patch` HEAD `d6e6bcaa8`; meta gitlink bumped). The only open Phase-4 item is **manual on-device verification, which the user will do via the GitHub release pipeline + Obtainium** — so it's gated on **Phase 6 (signing + distinct applicationId) and Phase 7 (release workflow)**. **Next = Phase 5 — but the user EXPANDED its scope (Session 6): the marker becomes interactive + always-present and must toggle title AND thumbnail. DESIGN (brainstorm) BEFORE coding; it revises the committed Phase-4 marker. See the "Phase 5 scope EXPANDED" note below for the full requirements + design tensions.** (Phase 6/7 for a signed APK can come before or after.) (Build verified each step: assembleDebug + dearrow unit tests 23/23. `runCheckstyle` is NOT a gate — upstream fails it with 2192 errors and CI doesn't run it; our dearrow files add 0 errors / 1 unavoidable override warning.)

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
- [x] Wire the non-recycled title sites (detail/player/dialog/queue) — unit C *(also covered the recycled play-queue list, see Decisions; compiled & committed `8ed625702`)*
- [x] Per-item indicator — no pre-existing "show original titles" setting exists (only `show_original_time_ago`, about timestamps), so added a settings-gated "Mark replaced titles" icon instead (default ON; `CenteredImageSpan` of `ic_stars` at the single applier chokepoint). Design in `dearrow-design.md` §7; committed `d6e6bcaa8`.
- [ ] Manual on-device verification — **via the GitHub release pipeline + Obtainium** (user's chosen flow, Session 6); depends on Phase 6 (signing/identity) + Phase 7 (release workflow).
- [x] Commit & push on client `patch`; bump pinned SHA in meta `patch` *(marker = client `d6e6bcaa8`)*

### Phase 5: DeArrow thumbnails + interactive toggle marker  *(scope EXPANDED Session 6 — see the "Phase 5 scope EXPANDED" note in Decisions)*
- [x] **Design first (brainstorm)** — the marker becomes interactive + always-present; this revises the Phase-4 marker (committed `d6e6bcaa8`). Resolve the open tensions (marker placement/clickability; unified per-item controller) before coding. *(Done Session 7: design = `dearrow-design.md` §8 — hybrid marker [static title star + interactive thumbnail-corner badge], unified `DeArrowItemController`. Full implementation plan written: `docs/superpowers/plans/2026-05-31-dearrow-thumbnails-toggle-marker.md`, 13 tasks. Both uncommitted.)*
- [x] Thumbnail selection: pure, testable `DeArrowThumbnailSelector` (mirrors `DeArrowTitleFormatter`: drop original, prefer locked, then top non-negative votes) + `DeArrowThumbnailUrl` builder (`https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=&time=`); `randomTime*videoDuration` fallback when no explicit timestamp. *(POJOs + parsing already exist from Phase 3.)*
- [x] `dearrow_replace_thumbnails` toggle + `DeArrowSettings.isThumbnailReplacementEnabled`; no-flicker Picasso load (original first; replace with `.noFade()`; 204/error → keep original; no placeholder/error drawable so failures don't clear the original).
- [x] Thumbnail replacement at **lists + video detail**. **Player thumbnail: include only if cheap; OK to SKIP if it needs MediaSession hooking** (bitmap drives notification/lockscreen/end-screen). Player *title* already done (Phase 4 Unit C).
- [x] **Interactive, always-present marker** — when DeArrow on, show the marker on every YouTube item: full opacity when a replacement exists, **faded when the video is absent from the DeArrow DB** (original shown). Tap toggles original <-> DeArrow for **both title and thumbnail together**; tap again reverts. (Replicates the DeArrow browser extension.)
- [ ] Verify across feed/search/detail (+ player if included); on-device via release + Obtainium.
- [x] Commit & push on client `patch`; bump pinned SHA in meta `patch` *(client recomposed to 3 commits `a860ce2a4..754992090`, force-pushed; meta gitlink bumped this commit)*

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
| Phase 4: DeArrow titles in Client | Code-complete (on-device check pending release) | 5/6 |
| Phase 5: DeArrow thumbnails + interactive marker | Code-complete (full build + on-device check pending) | 6/7 |
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
- **2026-05-31 (Session 6) — build FIXED; Session-5 diagnosis corrected.** The `-XX:-UseBiasedLocking` mitigation **did not work** — `nix run .#build` crashed again (`hs_err_pid398492` + `400603`, both with the flag confirmed active, `UseBiasedLocking = false`). Reproduced **3/3**, every crash a null deref (`si_addr=0x0`) *inside* `ObjectSynchronizer::inflate(...)+0x320`. The callers differed — interpreter (`InterpreterRuntime::monitorenter`) **and** C1 (`Runtime1::monitorenter`) — so it was **not** "a C2-compiled monitorenter" and **not** biased locking; the fault is in `inflate` itself. **Real root cause:** nixpkgs-unstable's `jdk11` is **source-built with gcc 15.2.0** (per the crash header), which miscompiles OpenJDK 11's HotSpot lock code; no JVM flag or Gradle setting can fix a miscompiled binary. **Fix:** flake now uses the **prebuilt `pkgs.temurin-bin-11`** (11.0.31, vendor binary built with an OpenJDK-11-era toolchain); removed the dead `extraJavaToolOptions`/`JAVA_TOOL_OPTIONS` plumbing. **Verified:** changing *only* the JDK → BUILD SUCCESSFUL in 6m48s, then `nix run .#build` end-to-end → 5 APKs (`app/build/outputs/apk/debug/PipePipe_5.1.1-{arm64-v8a,armeabi-v7a,x86,x86_64,universal}-debug.apk`). **Committed & pushed:** client `8ed625702` (Unit-C), meta `406c533` (this build fix). Observed upstream `applicationId` = `InfinityLoop1309.NewPipeEnhanced` (debug suffix `.debug`) — note for the Phase-6 PipePipe+ distinct id.
- **2026-05-31 (Session 6) — "Mark replaced titles" indicator (Phase 4 close).** Investigation found **no pre-existing "show original titles" behavior** to respect — the only `show_original_*` pref is `show_original_time_ago` (timestamps), so that half of the plan item was a false premise. Designed + user-approved a settings-gated marker instead (`dearrow-design.md` §7): a small leading `ic_stars` icon on replaced titles, tinted to the **title's own text colour** (chosen over a theme accent so it stays visible in dark mode), via a new `CenteredImageSpan` (minSdk 21 lacks `DynamicDrawableSpan.ALIGN_CENTER`). Implemented at the **single `DeArrowTitleApplier` chokepoint**, so all surfaces inherit it; new pref `dearrow_mark_replaced_titles` (default ON, depends on `dearrow_replace_titles`). Purely visual — never touches the `title` field / notifications / share. Committed `d6e6bcaa8` (client). **Manual on-device verification will be done via the release pipeline + Obtainium**, so it's deferred behind Phase 6/7 rather than local adb.
- **2026-05-31 (Session 6) — Phase 5 scope EXPANDED by user; marker becomes interactive (DESIGN before coding).** New requirements to replicate the DeArrow browser extension's on-YouTube behaviour — captured for next-session design, **NOT yet designed or built**:
  1. **Always-present marker, faded when no data.** With DeArrow on, show the small marker on *every* YouTube item — full opacity when a DeArrow title/thumbnail replacement exists, **faded/dimmed when the video is absent from the DeArrow DB** (original title + thumbnail shown). NOTE: this revises the committed Phase-4 marker (`d6e6bcaa8`), which only appears on replaced titles and is non-interactive.
  2. **Tap-to-toggle original <-> DeArrow, for title AND thumbnail together.** Tapping the marker temporarily reverts to the original title *and* thumbnail; tapping again restores the DeArrow versions.
  3. **Thumbnail sites:** lists + video detail for sure. Player/now-playing thumbnail = include only if cheap; **OK to SKIP DeArrow thumbnails in the player if it requires hooking MediaSession** (the bitmap also drives notification/lockscreen/end-screen). Player *title* replacement is already done (Phase 4 Unit C).
  - **Design tensions to resolve first (brainstorm next session):** (a) **Marker placement/clickability** — a `ClickableSpan` icon inside the title TextView fights the row's open-video tap; the extension overlays the icon on the **thumbnail corner** (a natural tap target). Likely move the marker to a small overlay `ImageView` on the thumbnail rather than the title `ImageSpan`. (b) **Unified per-item controller** — toggling title+thumbnail together needs one object per holder/site holding {original title, DeArrow title, original thumb URL, DeArrow thumb time/URL, toggle state, view refs}; this argues for merging `DeArrowTitleApplier` + the planned thumbnail applier into a single `DeArrowItemController` that fetches branding once and renders both + the marker + the toggle. (c) **Recycling** — marker state + toggle must reset on rebind (extend the `boundVideoId` guard). (d) Every YouTube item already calls `getBranding` (cached), so the faded-vs-full decision is free.
- **2026-05-31 (Session 8) — Phase 5 IMPLEMENTED (subagent-driven, then history recomposed).** Executed the 13-task plan (`docs/superpowers/plans/2026-05-31-dearrow-thumbnails-toggle-marker.md`) via fresh per-task subagents with spec-compliance review + build gates. Built the unified **`DeArrowItemController`** (renamed from `DeArrowTitleApplier`): a 3-arg title-only `apply` keeps player/dialog/queue byte-identical, a 7-arg `apply` (title + thumbnail + badge) drives lists + detail from one branding fetch. Two pure TDD units — **`DeArrowThumbnailSelector`** (NaN sentinel = keep original) + **`DeArrowThumbnailUrl`**. No-flicker `PicassoHelper.loadDeArrowThumbnail` (`noFade`, no placeholder/error). New **`dearrow_replace_thumbnails`** toggle depends on the **MASTER** toggle (not the titles sub-toggle); default ON via XML `defaultValue` + `getBoolean(key,true)` — **NOT** `NewPipeSettings` (§8.7 corrected, the existing four toggles work the same way). Hybrid badge: static title star (kept) + always-present thumbnail-corner badge (faded+non-clickable until data resolves; tap toggles title+thumbnail together). **Decisions baked in:** (a) the selector drops `original` submissions and falls back to a random frame, so a video whose ONLY thumbnail vote is "original" still gets a random-frame replacement — a one-line tunable documented in the selector Javadoc; (b) **player thumbnail skipped** (would need MediaSession hooking; §8.9); (c) the detail title is no longer marked during the loading phase (plain original until data resolves, then title+thumbnail+badge marked in one shot — flicker-free refinement over Phase 4). **Tests:** dearrow unit suite **40/40** (TitleFormatter 16, ResponseParser 7, ThumbnailSelector 11, ThumbnailUrl 6). **History:** the 10 per-task commits were recomposed via the git-rewrite skill (isolated worktree, byte-identical net diff verified) into **3 logical commits `a860ce2a4..754992090`** and **force-pushed** to `origin/patch` (`--force-with-lease`). **Caveat:** the full `nix run .#build` APK gate was interrupted and NOT re-run this session — per-task `assembleDebug` + the unit-test run all passed, but a clean full build + the on-device check remain (gated on Phase 6/7).
- **2026-05-31 (Session 5) — unit C + 2 deviations.** (1) **Recycled play-queue list included:** the queue surfaces titles in *two* places — the non-recycled now-playing title (`PlayQueueActivity.onMetadataUpdate`, the documented §4 ":492" site) AND a *recycled* queue list (`PlayQueueItemBuilder`/`PlayQueueItemHolder`, not in the §4 titles table). Per user decision, included the recycled list too (per-holder applier, unit-B pattern) so the queue matches the de-clickbaited feed. (2) **Null-URL hardening:** added `url != null` to `DeArrowTitleApplier.apply()`'s gate — `YoutubeStreamLinkHandlerFactory.getId(null)` throws an *unchecked* `NullPointerException` (via `new URI(null)`), which the existing `catch (ParsingException | IllegalArgumentException)` did not cover; `VideoDetailFragment.url` is `@Nullable`, so this was a latent crash. Also added `DeArrowTitleApplier.dispose()` for transient sites (wired to the dialog's dismiss). **All review-level only — not yet compiled (Nix gradle build still un-run) or committed.**
- **2026-05-31 (Session 4) — history squashed.** Client: 3 DeArrow commits → 1 (`51cd432d5`). Meta: 8 commits → 2 (build + docs). Both force-pushed; `backup/pre-squash-s4` kept in each repo. Pre-squash content verified byte-identical to the squashed result.

## Blockers
- None.

## Deferred / To verify
- **Baseline build** (`nix run .#build`) — **RESOLVED Session 6.** BUILD SUCCESSFUL, 5 debug APKs. The Session-5 biased-locking theory was wrong; real cause was the gcc-15-miscompiled source JDK, fixed by switching to prebuilt Temurin (see Session 6 note). Crash artifacts deleted Session 6.
- **Phase 3 gradle verification** — **RESOLVED Session 6.** `:app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.*'` ran green in `nix develop`: `DeArrowTitleFormatterTest` 16 + `DeArrowResponseParserTest` 7 = 23/23. Confirms the nanojson parser + that the service compiles in the full Android classpath.
- **Manual on-device verification of DeArrow titles + marker** — deferred to after Phase 6/7. Plan (user's): publish a signed APK via the GitHub release workflow, install with **Obtainium**, verify on a real device. Marker rendering (`CenteredImageSpan` alignment/visibility across themes) is view glue with no unit coverage, so this is its first real-device check.
