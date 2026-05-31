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

### Phase 5 — Thumbnails
1. `DeArrowThumbnailUrl` + `PicassoHelper.loadDeArrowThumbnail`.
2. Thumbnail replacement at the §4 sites, reusing the Phase-4 `boundVideoId` guard.
3. Player thumbnail flows into notification/end-screen for free.

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
