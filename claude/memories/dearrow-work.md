---
name: dearrow-work
description: DeArrow-related changes made in the PipePipeD fork
metadata:
  type: project
---

DeArrow integration work completed on 2026-06-01:

- **Cross-fade on thumbnail swap:** Added ~200ms `TransitionDrawable` cross-fade in `DeArrowItemController` when a DeArrow thumbnail replaces the original. Uses `FixedSizeTransitionDrawable` (drawable-internal, recycling-safe). Fixes the abrupt memory-cache pop.

- **Prefetch gated to community frames only:** `DeArrowPrefetcher.warmThumbnail` now calls `selectTime(branding, false)` -- only prefetches community-submitted frames, not random frames. Random frames were pure waste (204 responses cache nothing; bind re-fires anyway). Zero UX change.

- **Random-thumbnail fallback defaulted OFF:** Was replacing real channel thumbnails with unrepresentative random frames for videos with no community submission. Diagnosed via ADB (pulled watch-history DB, fetched live DeArrow branding/frames). Committed: client `e1a1ac9f7`, meta `b6dc8f1`.

- **Aspect-fit bug fixed:** `Transition/LayerDrawable` was reporting per-dimension-max intrinsic size, causing 4:3 original + 16:9 frame to pillarbox+stretch on the `fitCenter` detail header. `FixedSizeTransitionDrawable` pins the transition's intrinsic size to the incoming frame.

**How to apply:** don't revert the prefetch gate or the random-fallback default; both were deliberate quality fixes with on-device verification. See [[upstream-v523-rebase-toolchain]] for the current toolchain the DeArrow code builds against.
