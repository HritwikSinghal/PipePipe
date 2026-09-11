# DeArrow Integration — Design Blueprint

> Status: design complete (Phase 2). Implementation in Phases 3–5.
> Scope: crowdsourced de-clickbait **titles + thumbnails** for YouTube, behind settings toggles.
> Architecture: **client-only** — all logic in `PipePipeClient`; the `PipePipeExtractor` submodule stays **dormant** (no fork-active, no SHA bump). The only extractor-provided piece is video-ID parsing, already exposed via public API.

---

## 1. Why client-only (and not the SponsorBlock pattern)

SponsorBlock lives in the **extractor** (`SponsorBlockExtractorHelper`, called during `StreamInfo` extraction) because it only needs data for the **one video being watched** — segments are a player-time concern.

DeArrow is different: its whole point is de-clickbaiting **list items** (feed, search, related) **before you click**. Those are bulk `StreamInfoItem`s rendered in recycled `RecyclerView` holders — there is no single extraction point to hang a fetch on, and we must not fire one network call per list item during extraction. Therefore DeArrow is a **client-side, display-time** decoration: resolve a replacement at render time, apply it to the view, fall back to the original on any miss.

Everything DeArrow needs already exists client-side:
- Video-ID parsing: `YoutubeStreamLinkHandlerFactory.getInstance().getId(url)` (extractor public API).
- HTTP: `NewPipe.getDownloader().get(...)` (text body — fine for JSON).
- Reactive plumbing: **RxJava3** (`io.reactivex.rxjava3:rxjava:3.0.13`, `rxandroid:3.0.0`).
- JSON: **nanojson** (`com.grack.nanojson`, as used in `DownloaderImpl`).
- Images: **Picasso** (`PicassoHelper`), with its own OkHttp client + 512 MB disk cache.

---

## 2. DeArrow API reference

### 2.1 Branding endpoint (titles + thumbnail timestamps)
```
GET https://sponsor.ajay.app/api/branding/<hashPrefix>
```
- `hashPrefix` = first **4 hex chars** of `SHA-256(videoID)`.
- Returns **every video in that hash bucket** → one request covers many feed items (privacy + caching win).
- Response shape (per videoID key):
```jsonc
{
  "<videoID>": {
    "titles":     [{ "title": "…", "original": false, "votes": 3, "locked": false, "UUID": "…" }],
    "thumbnails": [{ "timestamp": 12.3, "original": false, "votes": 1, "locked": false, "UUID": "…" }],
    "randomTime": 0.21,        // 0–1 fraction of duration; thumbnail fallback
    "videoDuration": 612.0     // may be null
  },
  …
}
```

### 2.2 Title selection + formatting
1. Drop entries with `original == true`.
2. Prefer `locked == true`; otherwise the highest **non-negative** `votes`.
3. Leading `>` ⇒ **exact title**: strip the `>`, never auto-format.
4. Otherwise apply **Title-case** iff the auto-format pref is on; strip stray inline markers defensively.
5. Nothing qualifies ⇒ return `null` ⇒ keep the original title.

### 2.3 Thumbnail endpoint
```
GET https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=<id>&time=<seconds>
```
- `time` = chosen thumbnail `timestamp`; if no submission, optionally `randomTime * videoDuration`; else skip.
- `200` ⇒ JPEG bytes; `204` ⇒ no thumbnail ⇒ fall back to original.
- **Picasso fetches this URL directly** (its own OkHttp). The extractor `Downloader` returns a *text* body and cannot carry binary, so it is not used for thumbnails.

### 2.4 Privacy & etiquette
- hashPrefix mode only (server never sees the exact videoID).
- Long client cache TTL (~6 h) + bucket dedup keep request volume low; send an identifying User-Agent.
- **No auth/token.** Read endpoints (`GET /api/branding`, `getThumbnail`) are public — no API key/token/header. A locally-generated `userID` + userAgent are required *only* for POST submissions/voting, which are out of our display-only scope. (The $1 license key is for the browser extension, not the API.) Verified against wiki.sponsor.ajay.app/w/API_Docs/DeArrow (Session 3).

### 2.5 License / attribution
- DeArrow data + API are **GPL-3.0**; **attribution is required**. A DeArrow credit/links entry in settings is a **release blocker** (must ship before any public release in Phase 7).

---

## 3. Client design

New package: `org.schabi.newpipe.util.dearrow`.

### 3.1 `DeArrowService` (singleton)
```
Maybe<DeArrowBranding> getBranding(String videoId)   // empty == graceful fallback; never errors to UI
```
- **Hash-bucket cache**: `LruCache<String prefix, BucketResult>` where `BucketResult = { Map<String videoId, DeArrowBranding> entries, long fetchedAtMs }`.
  - Positive **and** negative caching in one structure: a videoID *absent* from an already-fetched bucket resolves to `Maybe.empty()` (no re-fetch).
  - TTL ~6 h (stamp `fetchedAtMs`; treat expired buckets as misses).
- **In-flight dedup**: `ConcurrentHashMap<String prefix, Maybe<BucketResult>>` holding `.cache()`d sources behind a per-prefix lock — a screenful of holders binding at once attaches to **one** network call.
- HTTP via `NewPipe.getDownloader().get(url, headers)`; parse with nanojson; map to POJOs.

### 3.2 POJOs
- `DeArrowBranding` { `List<DeArrowTitle>`, `List<DeArrowThumbnail>`, `double randomTime`, `Double videoDuration` }
- `DeArrowTitle` { `String title`, `boolean original`, `int votes`, `boolean locked`, `String uuid` }
- `DeArrowThumbnail` { `double timestamp`, `boolean original`, `int votes`, `boolean locked`, `String uuid` }

### 3.3 `DeArrowTitleFormatter` (pure, unit-testable)
The §2.2 algorithm, no Android deps → fast JUnit tests for: locked-wins, vote-sort, `>` exact-title, auto-format on/off, all-original→null, empty→null.

### 3.4 Thumbnails
- `DeArrowThumbnailUrl` builds the §2.3 generator URL from the chosen timestamp.
- `PicassoHelper.loadDeArrowThumbnail(ctx, url)` reuses the existing scale-down transform.
- **No-flicker pattern**: load the **original first** (existing baseline), then on DeArrow success replace into the same `ImageView` with `.noFade()`. `204`/error ⇒ no-op (original already showing). Picasso disk cache covers repeats.

### 3.5 Recycled async replacement — the hard part
Holders extend `InfoItemHolder`; the only hook is `updateFromItem` (no unbind/recycle hook). Each holder gains:
```
private String boundVideoId;
private Disposable deArrowDisposable;
```
In `updateFromItem`:
1. Set the **original** title/thumbnail synchronously (current behavior — guarantees a baseline).
2. `dispose()` the previous `deArrowDisposable`.
3. Gate: master toggle ON, the relevant sub-toggle ON, `serviceId == YouTube`, and `getId(url)` parses. Else stop (original stays).
4. Set `boundVideoId = videoId`.
5. Subscribe to `DeArrowService.getBranding(videoId).observeOn(mainThread)`; **inside the callback**:
   ```java
   if (!videoId.equals(boundVideoId)) return;   // recycled away → drop stale result
   ```
   then apply the replacement title/thumbnail.

Picasso auto-cancels a superseded load into the same view, so the thumbnail path is covered by (1)+(5) plus the guard. Fast-scroll storms are bounded by dispose-on-rebind + bucket dedup (no explicit debounce expected; revisit if needed).

### 3.6 Settings (mirror SponsorBlock)
Keys (`res/values/settings_keys.xml`, ~line 474 neighborhood):
- `dearrow_enable` — master toggle
- `dearrow_replace_titles`
- `dearrow_replace_thumbnails`
- `dearrow_auto_format_titles`
- `dearrow_home_page`, `dearrow_privacy`, `dearrow_attribution` — info/links (attribution = release blocker)

Files: `res/xml/dearrow_settings.xml` + `DeArrowSettingsFragment.java` (cloned from the SponsorBlock pair), registered in `SettingsResourceRegistry.java:48`, `res/xml/main_settings.xml`, and defaults in `NewPipeSettings.java`.

---

## 4. Hook sites (verified file:line)

### Titles (`setText`)
| Surface | File | Line | Recycled? |
|---|---|---|---|
| Feed/search/playlist/channel list (base; grid/card subclass) | `info_list/holder/StreamInfoItemHolder.java` | 83 | yes |
| Compact/sidebar list | `info_list/holder/StreamMiniInfoItemHolder.java` | 54 | yes |
| Video detail (fullscreen pass) | `fragments/detail/VideoDetailFragment.java` | 1808 | no |
| Video detail (after metadata) | `fragments/detail/VideoDetailFragment.java` | 1840 | no |
| Player overlay | `player/Player.java` | 3535 | no |
| Queue / now-playing | `player/PlayQueueActivity.java` | 492 | no |
| Long-press dialog | `info_list/dialog/InfoItemDialog.java` | 59 | no |
| Local DB playlist/history (DB title) | `local/.../LocalPlaylistStreamItemHolder.java` | 61 | yes · **deferrable** |

> Do **not** overwrite `VideoDetailFragment.title` (used by share/notification/history) — override the **TextView** only.
>
> **Line numbers last verified at the pre-squash client (content now in `51cd432d5`)** — the list/detail/player/dialog sites above are accurate; the Session-4 squash preserved content byte-for-byte, so they still apply, but re-grep before editing. **EXCEPTION:** the `PlayQueueActivity` queue-item title (~`:492`) was NOT re-confirmed — only the action-bar title surfaced; rediscover the queue-item bind site (likely a `PlayQueueItemBuilder`/holder) before editing.

### Thumbnails (`PicassoHelper.loadScaledDownThumbnail(ctx, url).into(view)`)
| Surface | File | Line |
|---|---|---|
| List (base) | `info_list/holder/StreamInfoItemHolder.java` | 120–121 |
| Compact list | `info_list/holder/StreamMiniInfoItemHolder.java` | 91–92 |
| Video detail | `fragments/detail/VideoDetailFragment.java` | 841 |
| Player | `player/Player.java` | 1431 |
| Local DB playlist/history | `local/.../LocalPlaylistStreamItemHolder.java` | 89–90 |

Central helper to extend: `util/PicassoHelper.java`. Video-ID source at every site: `item.getUrl()` / `info.getUrl()` → `YoutubeStreamLinkHandlerFactory.getInstance().getId(url)`.

---

## 5. Implementation phases

### Phase 4 — Titles
1. POJOs (`DeArrowBranding`/`DeArrowTitle`/`DeArrowThumbnail`), `DeArrowSettings` (reads prefs).
2. `DeArrowTitleFormatter` + unit tests.
3. `DeArrowService` (cache + dedup + nanojson parse).
4. Settings: keys, `dearrow_settings.xml`, `DeArrowSettingsFragment`, registration, `main_settings` entry, defaults.
5. Title hooks at all sites in §4 (recycled guard for holders; field-disposable for the rest).

### Phase 5 — Thumbnails + interactive toggle marker
> **Expanded & redesigned (Session 7).** The authoritative Phase-5 design is **§8** — it
> supersedes this stub and revises the §7 marker. Summary: thumbnails at lists + detail only
> (player skipped), plus an always-present, tappable thumbnail-corner badge that toggles title +
> thumbnail together. See §8 for the full spec.

---

## 6. Risks & edge cases
- **Recycling races** — the `boundVideoId` stale guard is mandatory; without it, late results land on the wrong row.
- **Scroll request storms** — bounded by dispose-on-rebind + hash-bucket dedup + long TTL.
- **`>` exact-title marker** — strip and never auto-format.
- **Hard YouTube gate** — `serviceId == YouTube` only; DeArrow API is YouTube-only.
- **Offline / local DB items** — fall back to stored title/thumbnail; local-history coverage is deferrable.
- **API etiquette** — hashPrefix bucket mode, ~6 h TTL, identifying User-Agent.
- **GPL-3.0 attribution** — settings credit/links entry is a release blocker (Phase 7).
- **Immutable model** — never mutate `StreamInfoItem`/`StreamInfo`; replace only at the view layer; never clobber `VideoDetailFragment.title`.

---

## 7. Phase 4 addendum — "Mark replaced titles" indicator

> Status: designed + approved (Session 6). There is **no** pre-existing "show original titles" setting in the app — the only `show_original_*` pref is `show_original_time_ago` (about *timestamps*), so the Phase-4 "respect existing behavior" sub-item is void. What remains is this opt-in indicator.

**Goal.** When DeArrow replaces a title, prefix a small icon so the user knows the title is crowdsourced (DeArrow data can be wrong/vandalized; the browser extension shows an indicator too). Default ON, behind a toggle.

**Setting** (mirrors the existing DeArrow toggles):
- Key `dearrow_mark_replaced_titles` (`settings_keys.xml`, `translatable="false"`).
- `SwitchPreference` in `dearrow_settings.xml`, `android:dependency="@string/dearrow_replace_titles_key"`, `defaultValue="true"`, after "Auto-format titles" — so it auto-disables when titles aren't being replaced.
- Strings `dearrow_mark_replaced_titles_title` ("Mark replaced titles") / `_summary`.
- `DeArrowSettings.isMarkReplacedTitlesEnabled(ctx)` → plain bool read, default `true` (consulted only once a replacement exists, like `isAutoFormatTitlesEnabled`).

**Rendering — single chokepoint.** `DeArrowTitleApplier.apply()` is the one place every surface (recycled holders + detail/player/dialog/queue) sets a replaced title, so the marker lives there, in the existing `replacement != null` branch:
- mark off → `setText(replacement)` (unchanged).
- mark on → `setText(SpannableStringBuilder[ CenteredImageSpan(icon) + " " + replacement ])`.
- Icon: `@drawable/ic_stars`, `.mutate()`, tinted to the title's current text color (`titleView.getCurrentTextColor()`) — guaranteed visible in every theme, unlike a theme accent which can collide with the background in dark mode — with bounds sized to the view's text size.
- Purely visual: only TextViews are touched; the `VideoDetailFragment.title` field, notifications, and share text are unaffected.
- Recycled-safe: holders set the plain original first (clearing any prior span); the `boundVideoId` stale-guard prevents cross-row leaks.

**New class.** `util/dearrow/CenteredImageSpan` — a vertical-centering `ImageSpan` (since `DynamicDrawableSpan.ALIGN_CENTER` is API 29 > minSdk 21).

**Testing.** The mark *decision* is a pref read; the *rendering* is view glue (no Robolectric in this project) → verified by `assembleDebug` + on-device via the release/Obtainium path. Pure formatter/parser unit tests are unchanged (23/23).

**Out of scope (YAGNI).** Tap-to-reveal-original; thumbnail marking (Phase 5); non-en translations (ship en-only, like the other DeArrow strings).

> **Revised by §8 (Session 7).** Phase 5 makes the marker interactive, so "tap-to-reveal-original"
> is now **in** scope (it's the toggle). The §7 inline title icon is retained but its role narrows
> to a *static recognition cue*; the new interactive control is a separate thumbnail-corner badge.

---

## 8. Phase 5 — DeArrow thumbnails + interactive toggle marker

> Status: **IMPLEMENTED** (Session 8, 2026-05-31) — client `patch` commits `a860ce2a4..754992090`
> (3 logical commits, force-pushed). Designed + approved via brainstorm (Session 7); mockups approved.
> Unit tests green (40/40 dearrow). The full `nix run .#build` APK gate was not re-run this session
> (per-task `assembleDebug` all passed); on-device check still deferred to Phase 6/7.
> **Supersedes** the §5 "Phase 5" stub and **revises** §7: the §7 inline title icon becomes a
> *static recognition cue*, and a new *always-present, interactive thumbnail-corner badge* becomes
> the toggle.

### 8.1 Approved decisions
- **Marker = hybrid.** Two distinct per-item signals on YouTube surfaces:
  - **Title star** — the §7 `CenteredImageSpan` of `ic_stars`, tinted to the title's text colour.
    *Static, recognition-only.* Shown **only while a DeArrow title is currently displayed**, so the
    user can tell *before clicking* that the title they're reading is the crowdsourced one.
    Governed by the existing `dearrow_mark_replaced_titles`.
  - **Thumbnail corner badge** — a new overlay `ImageView` at the thumbnail's **top-left** corner
    (the duration badge stays bottom-right, so no collision). *Always present* on every YouTube item
    when DeArrow is on, and the **only tap target**. Three visual states:
    - **Active** — has data, currently showing DeArrow (solid/tinted fill, filled star).
    - **Off / hollow** — has data, tapped to show original (dark fill, outline star) ⇒ "tap to
      restore DeArrow".
    - **Faded** — video not in the DeArrow DB; **non-clickable**, so taps fall through to open the
      video.
- **Toggle = temporary.** Tapping the badge flips title + thumbnail **together** between DeArrow and
  original; tap again restores. State is per-item and **resets on recycle** (lists) / lasts only for
  the screen's lifetime (detail). No persistent or cross-surface store.
- **"Has data" = title OR thumbnail.** The badge is *active* iff
  `(titles enabled AND a replacement title exists) OR (thumbnails enabled AND a replacement
  thumbnail exists)`; *faded* otherwise. A tap flips whichever replacements are effective.
- **Thumbnail sites = lists + video detail only.** **Player thumbnail is SKIPPED** — it feeds the
  MediaSession / notification / lockscreen / end-screen bitmap pipeline (`Player.initThumbnail` →
  `currentThumbnail`), too costly for the benefit. The player *title* is already de-clickbaited
  (Phase 4 Unit C), so the player still benefits.
- **Random-frame fallback = kept** (DeArrow-extension parity): a video with only a *title*
  submission still gets its thumbnail replaced with a `randomTime` frame.
  **`dearrow_replace_thumbnails` defaults ON.**
- **Settings = minimal:** exactly one new toggle (`dearrow_replace_thumbnails`); the badge has no
  pref of its own (it follows the master + sub-toggles).

### 8.2 Architecture — unified `DeArrowItemController`
Evolve the committed `DeArrowTitleApplier` into **`DeArrowItemController`**: one instance per holder
or non-recycled site. Chosen over two separate appliers (title + thumbnail) because the toggle must
flip title **and** thumbnail together — a single object holding both originals, both DeArrow
versions, the toggle state, and the view refs gives **one** branding fetch, **one** main-thread
render, **one** `boundVideoId` stale-guard, and **one** place the toggle lives. That is the leanest
and most optimized option: fewest allocations per visible row and no two-object recycle races.

Fields: `boundVideoId`, `Disposable disposable`, `boolean showingOriginal`, and cached
`originalTitle` / `originalThumbUrl` / `replacementTitle` / `replacementThumbUrl`. View refs:
`titleView` (required); `thumbnailView` + `badgeView` (nullable). At title-only sites (player,
dialog, queue) the latter two are null and the controller degrades to today's title-+-star behavior
with no badge and no toggle.

The heavy logic stays in small, pure, unit-tested units; the controller is a thin orchestrator
(gate → fetch once → compute via selectors → render).

### 8.3 New pure units (JUnit, zero Android deps)
- **`DeArrowThumbnailSelector.select(branding)` → frame time, or a "none" signal.** Mirrors
  `DeArrowTitleFormatter`: drop `original == true`; prefer `locked`; else the highest non-negative
  `votes`; use that entry's `timestamp` when present; else fall back to `randomTime * videoDuration`
  when both are available; else "none".
- **`DeArrowThumbnailUrl.build(videoId, timeSeconds)` → URL string:**
  `https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=<id>&time=<sec>`.

### 8.4 Picasso — no-flicker swap
`PicassoHelper.loadDeArrowThumbnail(url)`: reuse the existing scale-down transform, add `.noFade()`,
and use **no placeholder and no error drawable**. On `204`/error Picasso leaves the view's current
bitmap untouched, so the original (already loaded synchronously by the holder) stays — no flicker,
no blanking. Toggling back to the original re-loads the original URL (Picasso disk-cached, cheap).

### 8.5 Per-item flow
`apply(serviceId, url, originalTitle, originalThumbUrl)`:
1. Dispose any prior fetch; reset `showingOriginal = false`; clear cached replacements.
2. Baseline title/thumbnail already set by the holder. Badge → **GONE** unless gated-in; if gated,
   show it **faded** (pending result).
3. Gate: `url != null` AND (titles-on OR thumbs-on) AND `serviceId == YouTube` AND the id parses
   (`YoutubeStreamLinkHandlerFactory.getId`, multi-catch as today). On failure → badge GONE, return.
4. `boundVideoId = id`; subscribe `DeArrowService.getBranding(id).observeOn(mainThread)`. In the
   callback, **first** guard `id.equals(boundVideoId)` (drop stale recycled results), then:
   - `replacementTitle` = titles-on ? `DeArrowTitleFormatter.selectTitle(...)` : null.
   - `replacementThumbUrl` = thumbs-on ? (`DeArrowThumbnailSelector` → `DeArrowThumbnailUrl`) : null.
   - `hasData = replacementTitle != null || replacementThumbUrl != null`.
   - Badge → **active** + clickable if `hasData`; else stays **faded** + non-clickable.
   - If `hasData`, render the DeArrow state (title + star if `replacementTitle`; thumbnail swap if
     `replacementThumbUrl`).

Tap handler (attached only when `hasData`): flip `showingOriginal`; re-render the title (± star),
swap the thumbnail (DeArrow URL ↔ original URL, both via cached Picasso), and toggle the badge
active ↔ hollow. The badge `ImageView` consumes its own click so the row's open-video tap is not
triggered.

`dispose()` (transient sites, e.g. the long-press dialog): dispose the fetch, null `boundVideoId`.

### 8.6 Layout changes
Add a small overlay badge `ImageView` constrained to the thumbnail's **top-left** corner in: the
base list item, the grid/card variant, the compact/mini item, and the video-detail layout. (Exact
files + thumbnail view IDs + parent layout types are verified during planning.) The badge is
**non-clickable until `hasData`**, so faded badges let touches fall through to the row.

### 8.7 Settings
- New key `dearrow_replace_thumbnails` (`settings_keys.xml`, `translatable="false"`).
- `SwitchPreference` in `dearrow_settings.xml`, `android:dependency` on the master toggle,
  `defaultValue="true"`; strings `_title` / `_summary`. **No `NewPipeSettings.java` change:** the
  default comes from the XML `defaultValue` + the `getBoolean(key, true)` fallback in
  `DeArrowSettings`, exactly like the existing four DeArrow toggles (none of which appear in
  `NewPipeSettings`, which does not register `R.xml.dearrow_settings` for `setDefaultValues`).
- `DeArrowSettings.isThumbnailReplacementEnabled(ctx)` → `isEnabled(ctx) && <pref>`.
- The title star keeps `dearrow_mark_replaced_titles`. The badge has no pref: it shows iff
  master-on AND (titles-on OR thumbs-on).

### 8.8 Testing
- New pure suites: `DeArrowThumbnailSelectorTest` (locked-wins, vote-sort, original-dropped,
  explicit-timestamp, randomTime fallback, none-on-empty) and `DeArrowThumbnailUrlTest` (format,
  precision, id passthrough).
- `DeArrowTitleFormatterTest` (16) + `DeArrowResponseParserTest` (7) unchanged.
- Controller / Picasso / layout = view glue (no Robolectric) → covered by `assembleDebug` compile
  gate + on-device verification via the release/Obtainium path (same as Phase 4).

### 8.9 Out of scope (YAGNI)
Player thumbnail (and its notification/lockscreen/end-screen bitmap); persistent or cross-surface
toggle state; a dedicated badge pref; non-en translations; local DB/history thumbnails.
