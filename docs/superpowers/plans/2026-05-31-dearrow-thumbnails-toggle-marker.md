# DeArrow Thumbnails + Interactive Toggle Marker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DeArrow community thumbnails (lists + video detail) plus an always-present, tappable thumbnail-corner badge that toggles the DeArrow title **and** thumbnail together, behind one new settings toggle.

**Architecture:** Evolve the committed `DeArrowTitleApplier` into a unified `DeArrowItemController` (one branding fetch, one main-thread render, one `boundVideoId` stale-guard, one toggle, view refs for title + nullable thumbnail + nullable badge). Title-only sites (player/dialog/queue) keep today's behavior via a 3-arg `apply`. Two new pure units (`DeArrowThumbnailSelector`, `DeArrowThumbnailUrl`) hold the testable logic; a no-flicker `PicassoHelper.loadDeArrowThumbnail` swaps the image. A corner-pinned overlay `ImageView` (`@id/dearrow_badge`) is added to the four list/detail layouts.

**Tech Stack:** Java 11, AGP 7.3.0 / Gradle 7.5, RxJava3, nanojson, Picasso, JUnit (pure units only — no Robolectric). Build/test via Nix (`nix develop -c ./gradlew …` from `PipePipeClient/`).

**Authoritative design:** `docs/dearrow-design.md` §8 (this plan implements it). All paths below are relative to the `PipePipeClient/` submodule unless noted; line numbers were verified 2026-05-31 — **re-grep before editing** (the codebase shifts).

**Conventions to honor (from progress.md / §4):**
- Checkstyle (not in `assembleDebug`, not a CI gate, but keep new files clean): ≤100 cols, `final` on params/locals/for-vars, no unused imports, no trailing whitespace, trailing newline. Hand-check new files with `grep -nE '.{101,}' <file>`.
- No emoji in source/strings (a PostToolUse hook flags it). Use `[X]` / `CAUTION:` etc.
- `getBranding` is a `Maybe` → always use 2-arg `subscribe(onSuccess, onError)`.
- Never mutate extractor models; replace at the view layer only. Never overwrite `VideoDetailFragment.title`.
- Commit cadence: per task on the client `patch` branch. The meta gitlink bump + push is the LAST task; **push client `patch` BEFORE meta `patch`**.

---

## File Structure

**New files (under `app/src/main/java/org/schabi/newpipe/util/dearrow/`):**
- `DeArrowThumbnailSelector.java` — pure: branding → frame-time (seconds) or `NaN`.
- `DeArrowThumbnailUrl.java` — pure: `(videoId, timeSeconds)` → generator URL string.
- `DeArrowItemController.java` — renamed/evolved from `DeArrowTitleApplier.java` (via `git mv`).

**New test files (under `app/src/test/java/org/schabi/newpipe/util/dearrow/`):**
- `DeArrowThumbnailSelectorTest.java`
- `DeArrowThumbnailUrlTest.java`

**New drawables (`app/src/main/res/drawable/`):**
- `ic_dearrow_badge_active.xml` — filled white star.
- `ic_dearrow_badge_off.xml` — outline white star.
- (Reuse existing `@drawable/background_oval_black_transparent` as the chip background.)

**Modified:**
- `app/src/main/java/org/schabi/newpipe/util/PicassoHelper.java` — add `loadDeArrowThumbnail`.
- `app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowSettings.java` — add `isThumbnailReplacementEnabled`.
- `app/src/main/res/values/settings_keys.xml` — add `dearrow_replace_thumbnails_key`.
- `app/src/main/res/values/strings.xml` — add 2 strings.
- `app/src/main/res/xml/dearrow_settings.xml` — add the thumbnail `SwitchPreference`.
- Layouts: `list_stream_item.xml`, `list_stream_grid_item.xml`, `list_stream_card_item.xml`, `list_stream_mini_item.xml`, `fragment_video_detail.xml` — add `@id/dearrow_badge`.
- Holders: `StreamInfoItemHolder.java` (covers grid/card subclasses), `StreamMiniInfoItemHolder.java` — full `apply`.
- `fragments/detail/VideoDetailFragment.java` — full `apply` + badge + `dispose()` on teardown.
- Title-only rename-only: `player/Player.java`, `info_list/dialog/InfoItemDialog.java`, `player/PlayQueueActivity.java`, `player/playqueue/PlayQueueItemHolder.java`.
- Docs: `docs/dearrow-design.md` (§8.7 correction + §8 status), `docs/progress.md`.

---

## Task 1: Correct the §8.7 settings-defaults note in the design doc

**Why:** §8.7 says "default in `NewPipeSettings.java`", but `NewPipeSettings.initSettings()` does **not** call `setDefaultValues` on `R.xml.dearrow_settings`, and the existing four DeArrow toggles have **zero** references in `NewPipeSettings.java`. They get their `true` default purely from `android:defaultValue="true"` in the XML + the `getBoolean(key, true)` fallback in `DeArrowSettings`. The new toggle must follow that exact pattern; touching `NewPipeSettings` would diverge from the other toggles.

**Files:**
- Modify: `docs/dearrow-design.md` (§8.7, repo root — NOT the submodule)

- [ ] **Step 1: Edit §8.7**

In `docs/dearrow-design.md`, replace the §8.7 bullet:

```
- `SwitchPreference` in `dearrow_settings.xml`, `android:dependency` on the master toggle,
  `defaultValue="true"`; strings `_title` / `_summary`; default in `NewPipeSettings.java`.
```

with:

```
- `SwitchPreference` in `dearrow_settings.xml`, `android:dependency` on the master toggle,
  `defaultValue="true"`; strings `_title` / `_summary`. **No `NewPipeSettings.java` change:** the
  default comes from the XML `defaultValue` + the `getBoolean(key, true)` fallback in
  `DeArrowSettings`, exactly like the existing four DeArrow toggles (none of which appear in
  `NewPipeSettings`, which does not register `R.xml.dearrow_settings` for `setDefaultValues`).
```

- [ ] **Step 2: Commit (docs live in the meta-repo working tree, committed at the end with progress.md — for now just save).**

No commit yet; this file is committed in Task 13 alongside `progress.md`.

---

## Task 2: `DeArrowThumbnailSelector` (pure, TDD)

**Files:**
- Create: `app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelector.java`
- Test: `app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelectorTest.java`

**Selection rule (mirrors `DeArrowTitleFormatter`, per design §8.3 + the §8.1 "random-frame fallback kept"):**
1. Among `branding.getThumbnails()`, drop entries with `original == true`; among the rest prefer `locked`, else highest `votes`. An unlocked winner with `votes < 0` is rejected (→ no best).
2. If a best exists and `hasTimestamp()` → return its `timestamp`.
3. Otherwise (best without a timestamp, OR no best at all incl. title-only videos) → fall back to `randomTime * videoDuration` when `videoDuration != null` (aggressive parity with the DeArrow extension's "replace thumbnails on" mode).
4. Otherwise → `Double.NaN` (keep the original).

> **Documented trade-off:** because step 1 drops `original` entries and step 3 falls back to a random frame, a video whose only thumbnail submission is `original:true` (community said "the original is fine") still gets a random-frame replacement. This matches the approved §8.3 "drop original" rule and the extension's default-on behavior. If the user later wants to *respect* an original-vetted thumbnail, that is a one-line change in `selectBest` (rank `original` entries in and short-circuit to `NaN` when the overall best is `original`). Note it in the class Javadoc.

- [ ] **Step 1: Write the failing test**

`app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelectorTest.java`:

```java
package org.schabi.newpipe.util.dearrow;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

public class DeArrowThumbnailSelectorTest {

    private static final double EPS = 1e-9;

    private static DeArrowThumbnail thumb(final double timestamp, final boolean original,
                                          final int votes, final boolean locked) {
        return new DeArrowThumbnail(timestamp, original, votes, locked, "uuid");
    }

    private static DeArrowBranding branding(final List<DeArrowThumbnail> thumbs,
                                            final double randomTime, final Double duration) {
        return new DeArrowBranding(Collections.emptyList(), thumbs, randomTime, duration);
    }

    @Test
    public void nullBranding_returnsNaN() {
        assertTrue(Double.isNaN(DeArrowThumbnailSelector.selectTime(null)));
    }

    @Test
    public void explicitTimestamp_isReturned() {
        final DeArrowBranding b = branding(
                Collections.singletonList(thumb(42.5, false, 3, false)), 0.5, 100.0);
        assertEquals(42.5, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void lockedWins_overHigherVotedUnlocked() {
        final DeArrowBranding b = branding(Arrays.asList(
                thumb(10.0, false, 99, false),
                thumb(20.0, false, 1, true)), 0.5, 100.0);
        assertEquals(20.0, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void highestVotesWins_amongUnlocked() {
        final DeArrowBranding b = branding(Arrays.asList(
                thumb(10.0, false, 2, false),
                thumb(20.0, false, 7, false)), 0.5, 100.0);
        assertEquals(20.0, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void originalEntries_areDropped() {
        // Only entry is original -> no best -> random fallback (0.5 * 100 = 50).
        final DeArrowBranding b = branding(
                Collections.singletonList(thumb(10.0, true, 50, true)), 0.5, 100.0);
        assertEquals(50.0, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void bestWithoutTimestamp_fallsBackToRandomFrame() {
        // votes-only entry, no timestamp -> random fallback (0.25 * 200 = 50).
        final DeArrowBranding b = branding(
                Collections.singletonList(thumb(Double.NaN, false, 5, false)), 0.25, 200.0);
        assertEquals(50.0, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void titleOnlyVideo_noThumbnails_usesRandomFrame() {
        final DeArrowBranding b = branding(Collections.emptyList(), 0.1, 300.0);
        assertEquals(30.0, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void noThumbnails_noDuration_returnsNaN() {
        final DeArrowBranding b = branding(Collections.emptyList(), 0.1, null);
        assertTrue(Double.isNaN(DeArrowThumbnailSelector.selectTime(b)));
    }

    @Test
    public void negativeVotesUnlocked_isRejected_thenRandomFallback() {
        final DeArrowBranding b = branding(
                Collections.singletonList(thumb(10.0, false, -1, false)), 0.5, 80.0);
        // best rejected -> random fallback (0.5 * 80 = 40).
        assertEquals(40.0, DeArrowThumbnailSelector.selectTime(b), EPS);
    }

    @Test
    public void negativeVotesUnlocked_noDuration_returnsNaN() {
        final DeArrowBranding b = branding(
                Collections.singletonList(thumb(10.0, false, -1, false)), 0.5, null);
        assertTrue(Double.isNaN(DeArrowThumbnailSelector.selectTime(b)));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.DeArrowThumbnailSelectorTest'`
Expected: FAIL — `DeArrowThumbnailSelector` does not exist (compile error).

- [ ] **Step 3: Write the implementation**

`app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelector.java`:

```java
package org.schabi.newpipe.util.dearrow;

import java.util.List;

/**
 * Pure selection logic for DeArrow thumbnails (no Android dependencies).
 *
 * <p>Mirrors {@link DeArrowTitleFormatter}: drop {@code original} submissions, prefer
 * {@code locked}, otherwise the highest non-negative vote count. The chosen entry's explicit
 * frame {@code timestamp} is used when present; otherwise (including title-only videos with no
 * thumbnail submissions) it falls back to {@code randomTime * videoDuration} when the duration is
 * known. This matches the DeArrow extension's "replace thumbnails" behavior.</p>
 *
 * <p>Note: because {@code original} entries are dropped and the random-frame fallback applies when
 * no non-original submission wins, a video whose only thumbnail vote is "original" still receives a
 * random-frame replacement. To instead respect an original-vetted thumbnail, rank {@code original}
 * entries in {@link #selectBest} and short-circuit to {@link Double#NaN} when the overall best is
 * original.</p>
 */
public final class DeArrowThumbnailSelector {
    private DeArrowThumbnailSelector() {
    }

    /**
     * Resolve the DeArrow thumbnail frame time in seconds.
     *
     * @param branding the DeArrow branding (may be {@code null})
     * @return the frame time in seconds, or {@link Double#NaN} if the original thumbnail should be
     *         kept
     */
    public static double selectTime(final DeArrowBranding branding) {
        if (branding == null) {
            return Double.NaN;
        }

        final DeArrowThumbnail best = selectBest(branding.getThumbnails());
        if (best != null && best.hasTimestamp()) {
            return best.getTimestamp();
        }

        // No usable explicit frame (best without a timestamp, or no best incl. title-only videos):
        // fall back to the random frame when the duration is known.
        final Double duration = branding.getVideoDuration();
        if (duration != null) {
            return branding.getRandomTime() * duration;
        }
        return Double.NaN;
    }

    private static DeArrowThumbnail selectBest(final List<DeArrowThumbnail> thumbnails) {
        if (thumbnails == null || thumbnails.isEmpty()) {
            return null;
        }

        DeArrowThumbnail best = null;
        for (final DeArrowThumbnail candidate : thumbnails) {
            if (candidate == null || candidate.isOriginal()) {
                continue;
            }
            if (best == null || isBetter(candidate, best)) {
                best = candidate;
            }
        }

        // An unlocked winner is only acceptable if its votes are non-negative.
        if (best != null && !best.isLocked() && best.getVotes() < 0) {
            return null;
        }
        return best;
    }

    private static boolean isBetter(final DeArrowThumbnail candidate,
                                    final DeArrowThumbnail current) {
        if (candidate.isLocked() != current.isLocked()) {
            return candidate.isLocked();
        }
        return candidate.getVotes() > current.getVotes();
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.DeArrowThumbnailSelectorTest'`
Expected: PASS (10 tests).

- [ ] **Step 5: Checkstyle hand-check + commit**

Run: `grep -nE '.{101,}' app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelector.java app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelectorTest.java` → expect no output.

```bash
git add app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelector.java \
        app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailSelectorTest.java
git commit -m "feat(dearrow): pure DeArrowThumbnailSelector + tests"
```

---

## Task 3: `DeArrowThumbnailUrl` (pure, TDD)

**Files:**
- Create: `app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrl.java`
- Test: `app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrlTest.java`

**URL format (design §8.3):** `https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=<id>&time=<sec>`. The `<sec>` must be a plain decimal, locale-independent, no scientific notation, no trailing zeros (e.g. `12.34`, `50`, `0.5`, `0`). YouTube IDs are URL-safe (`[A-Za-z0-9_-]`) so no encoding is needed.

- [ ] **Step 1: Write the failing test**

`app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrlTest.java`:

```java
package org.schabi.newpipe.util.dearrow;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class DeArrowThumbnailUrlTest {

    private static final String BASE =
            "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=";

    @Test
    public void buildsUrlWithDecimalTime() {
        assertEquals(BASE + "dQw4w9WgXcQ&time=12.34",
                DeArrowThumbnailUrl.build("dQw4w9WgXcQ", 12.34));
    }

    @Test
    public void integerTime_hasNoTrailingZeros() {
        assertEquals(BASE + "abc&time=50",
                DeArrowThumbnailUrl.build("abc", 50.0));
    }

    @Test
    public void subSecondTime_isPreserved() {
        assertEquals(BASE + "abc&time=0.5",
                DeArrowThumbnailUrl.build("abc", 0.5));
    }

    @Test
    public void zeroTime_isPlainZero() {
        assertEquals(BASE + "abc&time=0",
                DeArrowThumbnailUrl.build("abc", 0.0));
    }

    @Test
    public void timeIsRoundedToMillisecondPrecision() {
        assertEquals(BASE + "abc&time=12.346",
                DeArrowThumbnailUrl.build("abc", 12.3456));
    }

    @Test
    public void videoIdIsPassedThroughVerbatim() {
        assertEquals(BASE + "a_b-C9&time=1",
                DeArrowThumbnailUrl.build("a_b-C9", 1.0));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.DeArrowThumbnailUrlTest'`
Expected: FAIL — `DeArrowThumbnailUrl` does not exist.

- [ ] **Step 3: Write the implementation**

`app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrl.java`:

```java
package org.schabi.newpipe.util.dearrow;

import java.util.Locale;

/**
 * Builds the DeArrow thumbnail-generator URL (no Android dependencies).
 *
 * <p>Format: {@code https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=<id>&time=<sec>}.
 * The time is formatted as a plain, locale-independent decimal with up to millisecond precision
 * and no trailing zeros. YouTube video IDs are URL-safe, so no escaping is applied.</p>
 */
public final class DeArrowThumbnailUrl {
    private static final String BASE =
            "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=";

    private DeArrowThumbnailUrl() {
    }

    /**
     * Build the generator URL for the given video and frame time.
     *
     * @param videoId     the YouTube video ID
     * @param timeSeconds the frame time in seconds
     * @return the fully-formed thumbnail URL
     */
    public static String build(final String videoId, final double timeSeconds) {
        return BASE + videoId + "&time=" + formatSeconds(timeSeconds);
    }

    private static String formatSeconds(final double seconds) {
        String formatted = String.format(Locale.ROOT, "%.3f", seconds);
        if (formatted.indexOf('.') >= 0) {
            // Strip trailing zeros, then a dangling decimal point.
            int end = formatted.length();
            while (end > 0 && formatted.charAt(end - 1) == '0') {
                end--;
            }
            if (end > 0 && formatted.charAt(end - 1) == '.') {
                end--;
            }
            formatted = formatted.substring(0, end);
        }
        return formatted;
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.DeArrowThumbnailUrlTest'`
Expected: PASS (6 tests).

- [ ] **Step 5: Checkstyle hand-check + commit**

Run: `grep -nE '.{101,}' app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrl.java app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrlTest.java` → expect no output.

```bash
git add app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrl.java \
        app/src/test/java/org/schabi/newpipe/util/dearrow/DeArrowThumbnailUrlTest.java
git commit -m "feat(dearrow): pure DeArrowThumbnailUrl builder + tests"
```

---

## Task 4: `PicassoHelper.loadDeArrowThumbnail` (no-flicker swap)

**Files:**
- Modify: `app/src/main/java/org/schabi/newpipe/util/PicassoHelper.java`

**Design §8.4:** reuse the existing scale-down `transformation`, add `.noFade()`, and use **no placeholder and no error drawable** so a 204/error leaves the view's current bitmap (the original, already loaded by the holder) untouched.

- [ ] **Step 1: Add the method**

In `PicassoHelper.java`, after `loadScaledDownThumbnail(...)` (currently ends ~line 169), add:

```java
    /**
     * Load a DeArrow replacement thumbnail into a view that already shows the original.
     *
     * <p>Uses the same scale-down transform as {@link #loadScaledDownThumbnail}, disables the
     * fade-in ({@code noFade}), and sets no placeholder or error drawable: on a 204/no-content or
     * any error, Picasso leaves the current bitmap in place, so the original stays visible with no
     * flicker.</p>
     *
     * @param url the DeArrow thumbnail-generator URL
     * @return the request creator, ready for {@code .into(view)}
     */
    public static RequestCreator loadDeArrowThumbnail(final String url) {
        return picassoInstance.load(url)
                .transform(transformation)
                .noFade();
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `nix develop -c ./gradlew :app:compileDebugJavaWithJavac`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Checkstyle hand-check + commit**

Run: `grep -nE '.{101,}' app/src/main/java/org/schabi/newpipe/util/PicassoHelper.java` → expect no NEW offending lines from your addition.

```bash
git add app/src/main/java/org/schabi/newpipe/util/PicassoHelper.java
git commit -m "feat(dearrow): PicassoHelper.loadDeArrowThumbnail (no-flicker swap)"
```

---

## Task 5: Thumbnail-replacement setting

**Files:**
- Modify: `app/src/main/res/values/settings_keys.xml`
- Modify: `app/src/main/res/values/strings.xml`
- Modify: `app/src/main/res/xml/dearrow_settings.xml`
- Modify: `app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowSettings.java`

- [ ] **Step 1: Add the key**

In `settings_keys.xml`, after the `dearrow_mark_replaced_titles_key` line (currently :477), add:

```xml
    <string name="dearrow_replace_thumbnails_key" translatable="false">dearrow_replace_thumbnails</string>
```

- [ ] **Step 2: Add the strings**

In `strings.xml`, after `dearrow_mark_replaced_titles_summary` (currently :680), add:

```xml
<string name="dearrow_replace_thumbnails_title">Replace thumbnails</string>
<string name="dearrow_replace_thumbnails_summary">Show DeArrow community thumbnails in place of the original.</string>
```

- [ ] **Step 3: Add the SwitchPreference**

In `dearrow_settings.xml`, inside the `<PreferenceCategory>`, after the `dearrow_mark_replaced_titles_key` `SwitchPreference`, add:

```xml
        <SwitchPreference
            app:iconSpaceReserved="false"
            android:dependency="@string/dearrow_enable_key"
            android:defaultValue="true"
            android:key="@string/dearrow_replace_thumbnails_key"
            android:summary="@string/dearrow_replace_thumbnails_summary"
            android:title="@string/dearrow_replace_thumbnails_title"/>
```

(Dependency is the **master** toggle, per §8.7 — thumbnails are independent of the titles sub-toggle.)

- [ ] **Step 4: Add the reader**

In `DeArrowSettings.java`, after `isTitleReplacementEnabled(...)` (ends :37), add:

```java
    /**
     * Whether replacement thumbnails should be shown (implies the master toggle is on).
     *
     * @param context any context
     * @return {@code true} if thumbnails should be replaced
     */
    public static boolean isThumbnailReplacementEnabled(final Context context) {
        return isEnabled(context) && prefs(context).getBoolean(
                context.getString(R.string.dearrow_replace_thumbnails_key), true);
    }
```

> Do **not** edit `NewPipeSettings.java` — see Task 1.

- [ ] **Step 5: Verify it compiles + commit**

Run: `nix develop -c ./gradlew :app:compileDebugJavaWithJavac`
Expected: BUILD SUCCESSFUL.

```bash
git add app/src/main/res/values/settings_keys.xml app/src/main/res/values/strings.xml \
        app/src/main/res/xml/dearrow_settings.xml \
        app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowSettings.java
git commit -m "feat(dearrow): add Replace thumbnails setting + reader"
```

---

## Task 6: Badge drawables

**Files:**
- Create: `app/src/main/res/drawable/ic_dearrow_badge_active.xml`
- Create: `app/src/main/res/drawable/ic_dearrow_badge_off.xml`

White star glyphs (active = filled, off = outline). They sit on the dark `background_oval_black_transparent` chip, so white reads in every theme without a theme tint. Star motif keeps the badge coherent with the title star (`ic_stars`).

- [ ] **Step 1: Create the filled star (active)**

`app/src/main/res/drawable/ic_dearrow_badge_active.xml`:

```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M12,17.27L18.18,21l-1.64,-7.03L22,9.24l-7.19,-0.61L12,2 9.19,8.63 2,9.24l5.46,4.73L5.82,21z" />
</vector>
```

- [ ] **Step 2: Create the outline star (off)**

`app/src/main/res/drawable/ic_dearrow_badge_off.xml`:

```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M22,9.24l-7.19,-0.62L12,2 9.19,8.63 2,9.24l5.46,4.73L5.82,21 12,17.27 18.18,21l-1.63,-7.03L22,9.24zM12,15.4l-3.76,2.27 1,-4.28 -3.32,-2.88 4.38,-0.38L12,6.1l1.71,4.04 4.38,0.38 -3.32,2.88 1,4.28L12,15.4z" />
</vector>
```

- [ ] **Step 3: Verify they compile (resources) + commit**

Run: `nix develop -c ./gradlew :app:processDebugResources`
Expected: BUILD SUCCESSFUL.

```bash
git add app/src/main/res/drawable/ic_dearrow_badge_active.xml \
        app/src/main/res/drawable/ic_dearrow_badge_off.xml
git commit -m "feat(dearrow): badge star drawables (active/off)"
```

---

## Task 7: Add the `@id/dearrow_badge` overlay to the four layouts

**Files:**
- Modify: `app/src/main/res/layout/list_stream_item.xml` (ConstraintLayout)
- Modify: `app/src/main/res/layout/list_stream_grid_item.xml` (ConstraintLayout)
- Modify: `app/src/main/res/layout/list_stream_card_item.xml` (ConstraintLayout)
- Modify: `app/src/main/res/layout/list_stream_mini_item.xml` (RelativeLayout)
- Modify: `app/src/main/res/layout/fragment_video_detail.xml` (FrameLayout `@id/detail_thumbnail_root_layout`)

All badges share `@+id/dearrow_badge` (one R.id, reused per layout — standard). Default `visibility="gone"`; the controller drives visibility/alpha/clickability. Add each badge **after** the thumbnail and duration views so it draws on top.

- [ ] **Step 1: list_stream_item.xml (ConstraintLayout)** — add before the closing `</androidx.constraintlayout.widget.ConstraintLayout>`:

```xml
    <ImageView
        android:id="@+id/dearrow_badge"
        android:layout_width="22dp"
        android:layout_height="22dp"
        android:layout_marginStart="3dp"
        android:layout_marginTop="3dp"
        android:padding="3dp"
        android:background="@drawable/background_oval_black_transparent"
        android:scaleType="fitCenter"
        android:src="@drawable/ic_dearrow_badge_active"
        android:contentDescription="@string/dearrow"
        android:visibility="gone"
        app:layout_constraintStart_toStartOf="@id/itemThumbnailView"
        app:layout_constraintTop_toTopOf="@id/itemThumbnailView" />
```

- [ ] **Step 2: list_stream_grid_item.xml (ConstraintLayout)** — same `<ImageView>` block as Step 1 (the thumbnail id is also `@id/itemThumbnailView`).

- [ ] **Step 3: list_stream_card_item.xml (ConstraintLayout)** — same `<ImageView>` block as Step 1.

- [ ] **Step 4: list_stream_mini_item.xml (RelativeLayout)** — add before the closing `</RelativeLayout>`:

```xml
    <ImageView
        android:id="@+id/dearrow_badge"
        android:layout_width="22dp"
        android:layout_height="22dp"
        android:layout_alignTop="@id/itemThumbnailView"
        android:layout_alignStart="@id/itemThumbnailView"
        android:layout_alignLeft="@id/itemThumbnailView"
        android:layout_marginStart="3dp"
        android:layout_marginLeft="3dp"
        android:layout_marginTop="3dp"
        android:padding="3dp"
        android:background="@drawable/background_oval_black_transparent"
        android:scaleType="fitCenter"
        android:src="@drawable/ic_dearrow_badge_active"
        android:contentDescription="@string/dearrow"
        android:visibility="gone" />
```

- [ ] **Step 5: fragment_video_detail.xml (FrameLayout)** — inside `@id/detail_thumbnail_root_layout`, add after the existing children (after `detail_position_view`), before the FrameLayout closes:

```xml
        <ImageView
            android:id="@+id/dearrow_badge"
            android:layout_width="32dp"
            android:layout_height="32dp"
            android:layout_gravity="top|left"
            android:layout_marginLeft="12dp"
            android:layout_marginTop="8dp"
            android:padding="5dp"
            android:background="@drawable/background_oval_black_transparent"
            android:scaleType="fitCenter"
            android:src="@drawable/ic_dearrow_badge_active"
            android:contentDescription="@string/dearrow"
            android:visibility="gone" />
```

- [ ] **Step 6: Verify resources + view binding compile + commit**

Run: `nix develop -c ./gradlew :app:processDebugResources :app:compileDebugJavaWithJavac`
Expected: BUILD SUCCESSFUL (this also confirms the generated `Activity*/Fragment*Binding` for `fragment_video_detail` now exposes `dearrowBadge`).

```bash
git add app/src/main/res/layout/list_stream_item.xml \
        app/src/main/res/layout/list_stream_grid_item.xml \
        app/src/main/res/layout/list_stream_card_item.xml \
        app/src/main/res/layout/list_stream_mini_item.xml \
        app/src/main/res/layout/fragment_video_detail.xml
git commit -m "feat(dearrow): add corner badge overlay to list + detail layouts"
```

---

## Task 8: Evolve `DeArrowTitleApplier` → `DeArrowItemController`

**Files:**
- Rename (git mv): `app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowTitleApplier.java` → `DeArrowItemController.java`
- Modify (field type + import only, behavior unchanged): `StreamInfoItemHolder.java`, `StreamMiniInfoItemHolder.java`, `VideoDetailFragment.java`, `Player.java`, `InfoItemDialog.java`, `PlayQueueActivity.java`, `PlayQueueItemHolder.java`

This task renames the class, adds the full (title+thumbnail+badge+toggle) `apply` overload and its internals, and **preserves the existing 3-arg `apply(titleView, serviceId, url)`** so all current call sites keep behaving exactly as today. After this task the app compiles and behaves identically to before (the new overload is unused until Tasks 9–11).

- [ ] **Step 1: Rename the file**

```bash
git mv app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowTitleApplier.java \
       app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowItemController.java
```

- [ ] **Step 2: Replace the class body**

Overwrite `DeArrowItemController.java` with:

```java
package org.schabi.newpipe.util.dearrow;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.text.Spannable;
import android.text.SpannableStringBuilder;
import android.view.View;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.content.res.AppCompatResources;
import androidx.core.graphics.drawable.DrawableCompat;

import org.schabi.newpipe.R;
import org.schabi.newpipe.extractor.ServiceList;
import org.schabi.newpipe.extractor.exceptions.ParsingException;
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeStreamLinkHandlerFactory;
import org.schabi.newpipe.util.PicassoHelper;

import io.reactivex.rxjava3.android.schedulers.AndroidSchedulers;
import io.reactivex.rxjava3.disposables.Disposable;

/**
 * Applies DeArrow replacements (title and/or thumbnail) to a view site, safely across
 * RecyclerView recycling, and drives the interactive corner badge.
 *
 * <p>One instance is owned per holder or per non-recycled view site. The caller sets the original
 * title/thumbnail synchronously, then calls {@link #apply}. A single branding fetch resolves both
 * replacements; a {@code boundVideoId} guard drops results that arrive after the holder has been
 * recycled onto a different item.</p>
 *
 * <p><b>Title-only sites</b> (player, dialog, queue) call the 3-arg {@link #apply(TextView, int,
 * String)} and behave exactly as before: a replacement title (optionally star-marked) with no
 * thumbnail swap, no badge, and no toggle.</p>
 *
 * <p><b>Full sites</b> (lists, video detail) call the 7-arg overload and additionally get a
 * thumbnail swap and an always-present corner badge: faded + non-clickable while no replacement
 * exists (taps fall through to open the video), active + clickable once data resolves. Tapping the
 * badge toggles title and thumbnail together between the DeArrow and original versions.</p>
 */
public final class DeArrowItemController {
    private static final float BADGE_FADED_ALPHA = 0.45f;

    private String boundVideoId;
    private Disposable disposable;
    private boolean showingOriginal;

    private String originalTitle;
    private String originalThumbUrl;
    private String replacementTitle;
    private String replacementThumbUrl;

    private TextView titleView;
    @Nullable
    private ImageView thumbnailView;
    @Nullable
    private ImageView badgeView;

    /**
     * Title-only entry point (no thumbnail, no badge, no toggle). Behaves as the former
     * {@code DeArrowTitleApplier}.
     *
     * @param newTitleView the title view to update (its context drives the preference lookup)
     * @param serviceId    the item's service ID; DeArrow is YouTube-only
     * @param url          the item's URL; a null or unparseable URL keeps the original title
     */
    public void apply(final TextView newTitleView, final int serviceId, final String url) {
        final CharSequence current = newTitleView.getText();
        applyInternal(newTitleView, null, null, serviceId, url,
                current == null ? null : current.toString(), null);
    }

    /**
     * Full entry point: title + thumbnail + interactive corner badge.
     *
     * @param newTitleView        the title view (required)
     * @param newThumbnailView    the thumbnail view, or {@code null} to skip thumbnail handling
     * @param newBadgeView        the corner badge view, or {@code null} for no badge
     * @param serviceId           the item's service ID; DeArrow is YouTube-only
     * @param url                 the item's URL; a null or unparseable URL keeps the originals
     * @param newOriginalTitle    the original title (restored when the badge is toggled off)
     * @param newOriginalThumbUrl the original thumbnail URL (restored when toggled off)
     */
    public void apply(final TextView newTitleView,
                      @Nullable final ImageView newThumbnailView,
                      @Nullable final ImageView newBadgeView,
                      final int serviceId, final String url,
                      final String newOriginalTitle, final String newOriginalThumbUrl) {
        applyInternal(newTitleView, newThumbnailView, newBadgeView, serviceId, url,
                newOriginalTitle, newOriginalThumbUrl);
    }

    private void applyInternal(final TextView newTitleView,
                               @Nullable final ImageView newThumbnailView,
                               @Nullable final ImageView newBadgeView,
                               final int serviceId, final String url,
                               final String newOriginalTitle,
                               final String newOriginalThumbUrl) {
        if (disposable != null) {
            disposable.dispose();
            disposable = null;
        }
        titleView = newTitleView;
        thumbnailView = newThumbnailView;
        badgeView = newBadgeView;
        originalTitle = newOriginalTitle;
        originalThumbUrl = newOriginalThumbUrl;
        replacementTitle = null;
        replacementThumbUrl = null;
        showingOriginal = false;

        // Hide the badge until gated-in (also clears any recycled state).
        if (badgeView != null) {
            badgeView.setOnClickListener(null);
            badgeView.setClickable(false);
            badgeView.setVisibility(View.GONE);
        }

        final Context context = newTitleView.getContext();
        final boolean titlesOn = DeArrowSettings.isTitleReplacementEnabled(context);
        final boolean thumbsEffective = thumbnailView != null
                && PicassoHelper.getShouldLoadImages()
                && DeArrowSettings.isThumbnailReplacementEnabled(context);

        String videoId = null;
        if (url != null && (titlesOn || thumbsEffective)
                && serviceId == ServiceList.YouTube.getServiceId()) {
            try {
                videoId = YoutubeStreamLinkHandlerFactory.getInstance().getId(url);
            } catch (final ParsingException | IllegalArgumentException e) {
                videoId = null;
            }
        }

        boundVideoId = videoId;
        if (videoId == null) {
            return;
        }

        // Gated-in: show the badge faded (pending result).
        if (badgeView != null) {
            showFadedBadge();
        }

        final String requestedVideoId = videoId;
        final boolean autoFormat = DeArrowSettings.isAutoFormatTitlesEnabled(context);
        disposable = DeArrowService.getInstance().getBranding(requestedVideoId)
                .observeOn(AndroidSchedulers.mainThread())
                .subscribe(branding -> {
                    if (!requestedVideoId.equals(boundVideoId)) {
                        return;
                    }
                    replacementTitle = titlesOn
                            ? DeArrowTitleFormatter.selectTitle(branding, autoFormat) : null;
                    replacementThumbUrl = thumbsEffective
                            ? resolveThumbUrl(requestedVideoId, branding) : null;
                    final boolean hasData =
                            replacementTitle != null || replacementThumbUrl != null;
                    if (hasData) {
                        render();
                        if (badgeView != null) {
                            showActiveBadge();
                        }
                    }
                    // else: badge stays faded + non-clickable.
                }, error -> { });
    }

    @Nullable
    private static String resolveThumbUrl(final String videoId, final DeArrowBranding branding) {
        final double time = DeArrowThumbnailSelector.selectTime(branding);
        if (Double.isNaN(time)) {
            return null;
        }
        return DeArrowThumbnailUrl.build(videoId, time);
    }

    /** Render the current toggle state for whichever replacements are effective. */
    private void render() {
        if (replacementTitle != null) {
            if (showingOriginal) {
                titleView.setText(originalTitle);
            } else {
                setMarkedTitle(titleView, replacementTitle);
            }
        }
        if (replacementThumbUrl != null && thumbnailView != null) {
            final Context ctx = thumbnailView.getContext();
            if (showingOriginal) {
                PicassoHelper.loadScaledDownThumbnail(ctx, originalThumbUrl).into(thumbnailView);
            } else {
                PicassoHelper.loadDeArrowThumbnail(replacementThumbUrl).into(thumbnailView);
            }
        }
    }

    private void toggle() {
        showingOriginal = !showingOriginal;
        render();
        showActiveBadge();
    }

    private void showFadedBadge() {
        badgeView.setVisibility(View.VISIBLE);
        badgeView.setAlpha(BADGE_FADED_ALPHA);
        badgeView.setClickable(false);
        badgeView.setOnClickListener(null);
        badgeView.setImageResource(R.drawable.ic_dearrow_badge_active);
    }

    private void showActiveBadge() {
        badgeView.setVisibility(View.VISIBLE);
        badgeView.setAlpha(1f);
        badgeView.setClickable(true);
        badgeView.setImageResource(showingOriginal
                ? R.drawable.ic_dearrow_badge_off : R.drawable.ic_dearrow_badge_active);
        badgeView.setOnClickListener(v -> toggle());
    }

    private static void setMarkedTitle(final TextView view, final String replacement) {
        if (DeArrowSettings.isMarkReplacedTitlesEnabled(view.getContext())) {
            final CharSequence marked = buildMarkedTitle(view, replacement);
            if (marked != null) {
                view.setText(marked);
                return;
            }
        }
        view.setText(replacement);
    }

    private static CharSequence buildMarkedTitle(final TextView view, final String replacement) {
        final Drawable icon = AppCompatResources.getDrawable(view.getContext(), R.drawable.ic_stars);
        if (icon == null) {
            return null;
        }
        final Drawable marker = icon.mutate();
        final int size = Math.round(view.getTextSize());
        marker.setBounds(0, 0, size, size);
        DrawableCompat.setTint(marker, view.getCurrentTextColor());

        final SpannableStringBuilder builder = new SpannableStringBuilder();
        builder.append(" ");
        builder.setSpan(new CenteredImageSpan(marker), 0, 1, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        builder.append(" ").append(replacement);
        return builder;
    }

    /**
     * Cancel any in-flight fetch and clear bound state. Call this when a view site is torn down
     * (a dismissed dialog, a destroyed fragment view) so a late result cannot touch a dead view.
     */
    public void dispose() {
        if (disposable != null) {
            disposable.dispose();
            disposable = null;
        }
        boundVideoId = null;
    }
}
```

- [ ] **Step 3: Update the 7 call sites (rename only — no behavior change)**

In each file, change the import `org.schabi.newpipe.util.dearrow.DeArrowTitleApplier` → `...DeArrowItemController`, the field type `DeArrowTitleApplier` → `DeArrowItemController`, and the `new DeArrowTitleApplier()` → `new DeArrowItemController()`. Rename the field/local for clarity (`deArrowTitleApplier` → `deArrowController`; in `InfoItemDialog` the local `titleApplier` → `controller`). **Leave the `.apply(view, serviceId, url)` and `.dispose()` calls as-is** (the 3-arg overload still exists).

Mechanical sweep (verify each file after):

```bash
grep -rl 'DeArrowTitleApplier' app/src/main/java/ | while read -r f; do
  sed -i 's/DeArrowTitleApplier/DeArrowItemController/g; s/deArrowTitleApplier/deArrowController/g' "$f"
done
# InfoItemDialog uses a local named titleApplier — fix separately:
sed -i 's/\btitleApplier\b/controller/g' \
  app/src/main/java/org/schabi/newpipe/info_list/dialog/InfoItemDialog.java
grep -rn 'DeArrowTitleApplier\|deArrowTitleApplier' app/src/main/java/   # expect: no output
```

> Note: `Player.java`, `InfoItemDialog.java`, `PlayQueueActivity.java`, `PlayQueueItemHolder.java` are now DONE (rename only — they stay title-only). `StreamInfoItemHolder`, `StreamMiniInfoItemHolder`, `VideoDetailFragment` are upgraded to the full `apply` in Tasks 9–11.

- [ ] **Step 4: Verify it compiles + assembleDebug (no behavior change yet)**

Run: `nix develop -c ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Checkstyle hand-check + commit**

Run: `grep -nE '.{101,}' app/src/main/java/org/schabi/newpipe/util/dearrow/DeArrowItemController.java` → expect no output.

```bash
git add -A
git commit -m "refactor(dearrow): DeArrowTitleApplier -> DeArrowItemController (title+thumbnail+badge core)"
```

---

## Task 9: Wire `StreamInfoItemHolder` (base — covers grid & card) to the full apply

**Files:**
- Modify: `app/src/main/java/org/schabi/newpipe/info_list/holder/StreamInfoItemHolder.java`

`StreamGridInfoItemHolder` and `StreamCardInfoItemHolder` only pass a layout id to `super(...)`; they inherit `updateFromItem`, so wiring the base holder covers all three layouts (all now carry `@id/dearrow_badge`).

- [ ] **Step 1: Add the badge field**

After the thumbnail field (`public final ImageView itemThumbnailView;`, ~:54), add:

```java
    public final ImageView dearrowBadgeView;
```

In **both** constructors' body region (the shared one at ~:66 does the `findViewById`s), after `itemThumbnailView = itemView.findViewById(R.id.itemThumbnailView);`, add:

```java
        dearrowBadgeView = itemView.findViewById(R.id.dearrow_badge);
```

(Returns `null` for any layout lacking the badge — safe.)

- [ ] **Step 2: Replace the title-only apply with the full apply**

Remove the existing call at ~:86:

```java
        deArrowController.apply(itemVideoTitleView, item.getServiceId(), item.getUrl());
```

Keep `itemVideoTitleView.setText(item.getName());` (the synchronous original). Then, **after** the original thumbnail load (currently ~:123-124, `PicassoHelper.loadScaledDownThumbnail(...).into(itemThumbnailView);`), add:

```java
        deArrowController.apply(itemVideoTitleView, itemThumbnailView, dearrowBadgeView,
                item.getServiceId(), item.getUrl(), item.getName(), item.getThumbnailUrl());
```

- [ ] **Step 3: Verify it compiles + assembleDebug**

Run: `nix develop -c ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add app/src/main/java/org/schabi/newpipe/info_list/holder/StreamInfoItemHolder.java
git commit -m "feat(dearrow): thumbnail + toggle badge in list/grid/card holders"
```

---

## Task 10: Wire `StreamMiniInfoItemHolder` to the full apply

**Files:**
- Modify: `app/src/main/java/org/schabi/newpipe/info_list/holder/StreamMiniInfoItemHolder.java`

- [ ] **Step 1: Add the badge field + lookup**

After `public final ImageView itemThumbnailView;` (~:26), add:

```java
    public final ImageView dearrowBadgeView;
```

In the constructor (~:33), after `itemThumbnailView = itemView.findViewById(R.id.itemThumbnailView);`, add:

```java
        dearrowBadgeView = itemView.findViewById(R.id.dearrow_badge);
```

- [ ] **Step 2: Replace the title-only apply with the full apply**

Remove the call at ~:57:

```java
        deArrowController.apply(itemVideoTitleView, item.getServiceId(), item.getUrl());
```

Keep `itemVideoTitleView.setText(item.getName());`. After the original thumbnail load (~:94-95), add:

```java
        deArrowController.apply(itemVideoTitleView, itemThumbnailView, dearrowBadgeView,
                item.getServiceId(), item.getUrl(), item.getName(), item.getThumbnailUrl());
```

- [ ] **Step 3: Verify it compiles + assembleDebug**

Run: `nix develop -c ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add app/src/main/java/org/schabi/newpipe/info_list/holder/StreamMiniInfoItemHolder.java
git commit -m "feat(dearrow): thumbnail + toggle badge in mini/compact holder"
```

---

## Task 11: Wire `VideoDetailFragment` (full apply + dispose)

**Files:**
- Modify: `app/src/main/java/org/schabi/newpipe/fragments/detail/VideoDetailFragment.java`

The detail thumbnail loads in `initThumbnailViews(info)` (def ~:842, called from `handleResult` ~:1937). The full apply must run **after** that, so the original thumbnail baseline is set first. Re-grep line numbers before editing.

- [ ] **Step 1: showLoading — drop the title-only apply**

At showLoading (~:1810-1811), keep `binding.detailVideoTitleView.setText(title);` and **remove**:

```java
        deArrowController.apply(binding.detailVideoTitleView, serviceId, url);
```

(During loading the thumbnail is cleared anyway, ~:1829. The title shows the original until data resolves — an intentional, flicker-free refinement over Phase 4.)

- [ ] **Step 2: handleResult — drop the early title-only apply**

At handleResult (~:1843-1844), keep `binding.detailVideoTitleView.setText(title);` and **remove**:

```java
        deArrowController.apply(binding.detailVideoTitleView, serviceId, url);
```

- [ ] **Step 3: handleResult — add the full apply after initThumbnailViews**

Immediately after `initThumbnailViews(info);` (~:1937), add:

```java
        deArrowController.apply(binding.detailVideoTitleView, binding.detailThumbnailImageView,
                binding.dearrowBadge, info.getServiceId(), url, info.getName(),
                info.getThumbnailUrl());
```

(`url` is the fragment field set by `setInitialData`; `binding.dearrowBadge` is generated from the `@id/dearrow_badge` added in Task 7 Step 5.)

- [ ] **Step 4: Dispose on view teardown**

Find `onDestroyView` (`grep -n 'public void onDestroyView' app/.../VideoDetailFragment.java`). Before `binding` is nulled / at the start of the method body, add:

```java
        deArrowController.dispose();
```

If there is no `onDestroyView`, add the call at the start of the existing `onDestroy()`. This prevents a late branding callback from touching destroyed views.

- [ ] **Step 5: Verify it compiles + assembleDebug**

Run: `nix develop -c ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add app/src/main/java/org/schabi/newpipe/fragments/detail/VideoDetailFragment.java
git commit -m "feat(dearrow): thumbnail + toggle badge on video detail"
```

---

## Task 12: Full build + unit-test gate

**Files:** none (verification only).

- [ ] **Step 1: Run all DeArrow unit tests**

Run: `nix develop -c ./gradlew :app:testDebugUnitTest --tests 'org.schabi.newpipe.util.dearrow.*'`
Expected: PASS — `DeArrowTitleFormatterTest` (16) + `DeArrowResponseParserTest` (7) + `DeArrowThumbnailSelectorTest` (10) + `DeArrowThumbnailUrlTest` (6) = **39/39**.

- [ ] **Step 2: Full debug build**

Run (from the meta repo root): `nix run .#build`
Expected: BUILD SUCCESSFUL, 5 debug APKs in `PipePipeClient/app/build/outputs/apk/debug/`.

- [ ] **Step 3: Checkstyle sanity on all new/changed dearrow files**

Run: `grep -nE '.{101,}' app/src/main/java/org/schabi/newpipe/util/dearrow/*.java app/src/test/java/org/schabi/newpipe/util/dearrow/*.java` → expect no output.

(No commit — this task only gates.)

---

## Task 13: Update trackers, commit docs, bump the meta gitlink

**Files (meta repo root unless noted):**
- Modify: `docs/dearrow-design.md` (§8 status line)
- Modify: `docs/progress.md`
- Bump: `PipePipeClient` submodule gitlink

- [ ] **Step 1: Mark §8 implemented**

In `docs/dearrow-design.md`, update the §8 status blockquote (currently "designed + approved via brainstorm (Session 7…)") to note it is implemented, with the client commit range from this plan.

- [ ] **Step 2: Update progress.md**

- Mark Phase 5 tasks `[x]` (design; selector+url; setting+picasso; thumbnail at lists+detail; interactive badge; commit/bump). Leave the cross-feature on-device verification item gated on Phase 6/7 (consistent with Phase 4).
- Recount the Status Summary row for Phase 5 (e.g. `6/7`, "Code-complete (on-device check pending release)").
- Bump "Last updated" and the Session counter.
- Add a Decisions & Notes entry: unified `DeArrowItemController`; thumbnail selector trade-off (drops `original` → random-frame fallback can replace an original-vetted thumbnail; one-line tunable); player thumbnail skipped; detail title no longer marked during loading (flicker-free refinement).

- [ ] **Step 3: Commit the client branch (already committed per-task) and push**

```bash
cd PipePipeClient
git log --oneline -8     # confirm Tasks 2-11 commits are present
git push origin patch
```

- [ ] **Step 4: Bump the meta gitlink + commit docs, then push (client first — already pushed in Step 3)**

```bash
cd ..                    # meta repo root
git add PipePipeClient docs/dearrow-design.md docs/progress.md
git commit -m "feat(dearrow): Phase 5 thumbnails + interactive toggle badge; bump client"
git push origin patch
```

- [ ] **Step 5: Verify the gitlink resolves**

Run: `git submodule status` → `PipePipeClient` should show the new client `patch` HEAD (the one pushed in Step 3), with no `+`/`-` prefix surprises.

---

## Self-Review (completed during planning)

**Spec coverage (design §8):**
- §8.1 hybrid marker (title star + corner badge, 3 states) → Tasks 6, 7, 8 (`showFadedBadge`/`showActiveBadge`, filled/outline drawables, faded non-clickable).
- §8.1 temporary toggle, title+thumbnail together, resets on recycle → Task 8 (`toggle`, `render`, `boundVideoId` guard + per-apply reset).
- §8.1 "has data" = title OR thumbnail → Task 8 (`hasData = replacementTitle != null || replacementThumbUrl != null`).
- §8.1 thumbnails lists + detail only, player skipped → Tasks 9, 10, 11; player stays title-only (Task 8 rename only).
- §8.1 random-frame fallback + `dearrow_replace_thumbnails` default ON → Tasks 2, 5.
- §8.1 minimal settings (one toggle) → Task 5.
- §8.2 unified controller → Task 8.
- §8.3 pure units → Tasks 2, 3.
- §8.4 no-flicker Picasso → Task 4.
- §8.5 per-item flow → Task 8 `applyInternal` (matches steps 1-4 incl. faded-pending then active-on-data).
- §8.6 layout badges → Task 7.
- §8.7 settings + the corrected NewPipeSettings note → Tasks 1, 5.
- §8.8 tests → Tasks 2, 3 (pure); view glue via build gate + on-device (Task 12 + Phase 6/7).
- §8.9 out of scope → respected (no player thumbnail, no persistent toggle, no badge pref, en-only).

**Type/signature consistency:** `selectTime` (NaN sentinel) used by `resolveThumbUrl`; `DeArrowThumbnailUrl.build(String, double)` matches its call; `loadDeArrowThumbnail(String)` / `loadScaledDownThumbnail(Context, String)` match Picasso call sites; `apply` 3-arg and 7-arg overloads both present; `dearrowBadgeView` (holders) vs `binding.dearrowBadge` (detail) are distinct binding paths for the same `@id/dearrow_badge`.

**No placeholders:** every code step contains complete code; commands have expected output.
