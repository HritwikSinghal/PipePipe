# Project: PipePipe+ — DeArrow support & signed release fork

> Last updated: 2026-06-01 | Phases 1–7 done; Phase 8 (upstream-sync) pending

## Overview
Personal fork of **PipePipe** (a NewPipe-based Android client) adding **DeArrow** support — crowdsourced de-clickbait **titles + thumbnails** for YouTube — while tracking upstream `InfinityLoop1308/PipePipe`. PipePipe is a thin meta-repo; real code lives in submodules (`PipePipeClient` = the app, `PipePipeExtractor` = the extractor lib). Strategy: **fork only what we modify** — only `PipePipeClient` is forked (to `HritwikSinghal/PipePipeClient`, branch `patch`); the extractor stays upstream-pinned/dormant. The meta-repo's `patch` branch repoints the client submodule at our fork and is the **default branch** on origin. End state: `git fetch upstream` + rebase keeps us current, `nix run .#build` produces a signed **PipePipe+** APK (distinct `applicationId`, installs alongside the official app), and a `workflow_dispatch` GitHub Actions release publishes a signed APK (keystore via GitHub Secrets).

## Current State
- **Meta `patch`** = **3 logical commits** atop `main` (upstream v5.1.1): `build(nix)` (toolchain flake + submodule wiring), `ci(release)` (signed-release pipeline + CI cache tuning), `docs` (README/design/progress + client gitlink pin). History squashed from 30 commits on 2026-06-01 for upstream-rebase ease.
- **Client `patch`** = **3 logical commits** atop upstream/dev `188c64eb9`: `feat(dearrow)` (titles + thumbnails across all surfaces), `perf(detail)` (instant video-detail header), `build(release)` (PipePipe+ identity, universal APK, R8 toggle). Squashed from 22 commits.
- **Submodule pins:** `PipePipeClient` @ fork `patch` HEAD; `PipePipeExtractor` @ upstream `871ea2d` (dormant); `PipePipe.wiki` never initialized. `.gitmodules`: client → fork `patch`; extractor + wiki → upstream.
- **Backups:** `backup/pre-squash-s4` in both repos (older pre-squash tip); the pre-2026-06-01-squash tips are recoverable from reflog/`origin`. Safe to delete once confirmed good.
- **Build/release:** `nix run .#build` → signed PipePipe+ universal APK; `.#debug` for fast iteration; `.#install` pushes to an ADB device; `workflow_dispatch` release pipeline live (publishes to GitHub Releases, consumed via Obtainium). Verified on-device (Pixel 10a).
- **Upstream drift:** upstream/dev tip still `188c64eb9` — no drift; both `patch` branches current.

## Architecture & Key Decisions
- **Branching model:** track upstream `main`; work lives on `patch` in both the meta-repo and the client fork. Fork only `PipePipeClient`; extractor stays upstream-pinned/dormant (its fork was deleted — no unique work); `PipePipe.wiki` never forked. `patch` is the default branch on both forks.
- **Gitlink push ordering (standing gotcha):** always push the **client `patch` BEFORE** the meta gitlink bump — else a recursive clone can't resolve the gitlink in the window between.
- **Rebase-safe additive pattern:** all fork build changes are additive end-of-file blocks (`-PforkVersionName/Code`, `-PforkAbiFilter`, `-PforkMinify`, signing) that reconfigure `android{}` *after* the upstream DSL — with the fork properties absent, upstream's build is byte-for-byte unchanged (preserves F-Droid reproducibility). Same principle in client code: replace at the **view layer**, never mutate immutable extractor models, never overwrite `VideoDetailFragment.title` (used by share/notification/history).
- **DeArrow = client-only, display-time.** Unlike SponsorBlock (extractor-side, player-time), DeArrow de-clickbaits **list items** before you click — a view-layer decoration resolved at render time, falling back to the original on any miss. Only extractor dependency: `YoutubeStreamLinkHandlerFactory.getId()` (public API). Covers titles + thumbnails behind toggles across all YouTube surfaces (lists/feed/history/detail/player/queue/dialog).
- **Stack facts:** client uses **RxJava3**, JSON via **nanojson**, images via **Picasso** (its own OkHttp). Branding via `DeArrowService.getBranding(videoId)` → `Maybe<DeArrowBranding>` (hash-bucket cache, memory→disk→network with stale-while-revalidate, 404-only negative caching, bounded transient retry). Pure/testable cores: `DeArrowTitleFormatter`, `DeArrowThumbnailSelector`, `DeArrowThumbnailUrl`, `DeArrowResponseParser`, `DeArrowDiskCache` (63 unit tests).
- **Build toolchain = the project's own:** AGP 7.3.0, Gradle 7.5, Kotlin 1.7.20, compileSdk/targetSdk 33, minSdk 21, Java 11. Flake pins **prebuilt Temurin JDK 11** — nixpkgs `jdk11` is source-built with gcc 15, which **miscompiles** OpenJDK 11's HotSpot lock code (SIGSEGV in `ObjectSynchronizer::inflate`); Gradle 7.5/AGP 7.3 are also incompatible with JDK 17+. Platform 33 + build-tools 30.0.3/33.0.1 + aapt2 override; **no NDK** (`:ffmpeg` ships a prebuilt `ffmpeg-kit.aar` with native libs for `arm64-v8a` + `x86_64` only — hence the single universal APK loses nothing vs the old per-ABI splits).
- **Signing / identity:** keystore via **GitHub Secrets** (public repo — never committed; local signing uses a gitignored auto-generated keystore). App name **"PipePipe+"**, `applicationIdSuffix ".plus"` (`…NewPipeEnhanced.plus`). PKCS12 keystore needs store==key password (separate passwords → "final block not properly padded"). Keystore + passwords backed up at `~/.pipepipe-fork-keystore/` (not in git).
- **Gotchas:** checkstyle (100-col, `final` params, no unused imports, trailing newline) runs over `src/main`+`src/test` but is NOT in `assembleDebug` and NOT a CI gate (upstream fails it with 2192 errors); hand-check new files. An emoji PostToolUse hook blocks edits to files containing emoji (the edit still applies) — don't introduce new emoji. `getBranding` is a `Maybe` — use the 2-arg `subscribe(onSuccess, onError)`.

## Plan / Phase Status
| Phase | Status | Progress |
|-------|--------|----------|
| 1: Foundation — Nix toolchain, branching & submodule wiring | Done | 7/7 |
| 2: Map SponsorBlock & design DeArrow | Done | 4/4 |
| 3: DeArrow service in the Client | Done | 5/5 |
| 4: DeArrow titles in the Client | Done (on-device verified) | 6/6 |
| 5: DeArrow thumbnails + interactive marker | Done (on-device verified) | 7/7 |
| 6: Build config — versioning, identity, signing, nix build | Done | 6/6 |
| 7: Release workflow & default branch | Done (release published; installed on-device) | 5/5 |
| 8: Upstream-sync maintenance & docs | Pending | 0/4 |

**Phase 8 (remaining):**
- [ ] Document/script the sync flow: rebase meta `patch` on upstream `main`; rebase client `patch` on its upstream; re-pin SHAs.
- [ ] Add maintenance notes to README/CLAUDE.md.
- [ ] Optional: scheduled CI to detect upstream updates.
- [ ] Final end-to-end verification (build + install) and wrap-up.

## Reference
- **Design/investigation docs:** `docs/dearrow-design.md` (blueprint, hook sites, hybrid-marker design); `docs/dearrow-perf-investigation.md` (list-latency root cause + before/after).
- **Fresh-clone setup:** `git clone --recursive git@github.com:HritwikSinghal/PipePipe.git && cd PipePipe && git checkout patch && git submodule update --init`. Build: `nix run .#build` (first run ~10–40 min). Unit tests: `cd PipePipeClient && nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.*'`.

## Deferred / To verify
DeArrow bug-hunt **Low** findings (Session 13) — documented, not yet fixed:
- **L1** — toggle-to-original shows the placeholder for blank stored thumbnails. `DeArrowItemController.render()` reloads `originalThumbUrl` on toggle-off; for local-DB items with a blank URL this loads the dummy placeholder. Fix: skip the reload when `originalThumbUrl` is blank.
- **L2** — the `getBranding` in-flight cohort all resolve empty on a transient failure; the cache self-heals (next rebind re-fetches) but the `DeArrowService` Javadoc overstates the guarantee. Fix: correct the Javadoc, or re-fetch per call site.
- **L3** — `backoffMillis` shift (`RETRY_BASE_DELAY_MS << (attempt-1)`) overflows past ~53 retries; safe at `MAX_RETRIES = 2`. Add a `Math.min(..., MAX_BACKOFF)` cap if ever made configurable.
- **L4** — `DeArrowTitleFormatter.toTitleCase` leaves a double space for a bare `>` token (unlikely in practice). Normalize whitespace defensively if desired.

## Blockers
- None.
