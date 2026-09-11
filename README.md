# PipePipeD

**PipePipeD** is a personal, signed fork of [PipePipe](https://github.com/InfinityLoop1308/PipePipe)
(a NewPipe-based Android client) that adds **DeArrow** support and a reproducible Nix/CI
**signed-release** pipeline. It installs **alongside** the official app (distinct application ID
`wtf.pipepiped.release`, app name "PipePipeD") and tracks upstream `InfinityLoop1308/PipePipe`, staying
current by rebasing.

> This top portion documents only how **PipePipeD** differs from upstream. The complete, unmodified
> upstream PipePipe README begins at [**"PipePipe (upstream)"**](#pipepipe-upstream) further down.
>
> Maintainers: keep the *changes from upstream* list in sync with `docs/progress.md` whenever fork
> behavior changes (see `CLAUDE.md`).

## About this fork

PipePipe is a thin meta-repo: the real code lives in submodules (`PipePipeClient` is the app,
`PipePipeExtractor` is the extractor library). PipePipeD follows a **fork-only-what-we-modify**
strategy — only `PipePipeClient` is forked (to `HritwikSinghal/PipePipeClient`, branch `patch`);
the extractor stays pinned to upstream. This meta-repo's `patch` branch repoints the client
submodule at the fork and is the default branch.

The goal is to stay a thin, rebase-friendly layer on top of PipePipe: `git fetch upstream` + rebase
keeps the fork current, and all fork build changes are additive so upstream's build stays
byte-for-byte unchanged when the fork properties are absent (preserving F-Droid reproducibility).
DeArrow itself is implemented entirely in the client at the **view layer**, resolved at render time
with a fall-back to the original on any miss — it never mutates extractor models.

## PipePipeD — changes from upstream

Everything in this section is what differs from upstream; the rest of this README (below) is
upstream's, unchanged.

### DeArrow — crowdsourced de-clickbait titles & thumbnails (YouTube)
- **Replacement titles** from the DeArrow community on every surface: feed/lists, video detail, the
  player, the now-playing queue, and info dialogs. Optional auto-formatting of SHOUTING titles.
  This includes the **experimental Compose UI** (*Settings -> Appearance -> Use experimental new
  UI*): with it on, upstream routes the channel page, search, related videos, remote playlists,
  watch history and local playlists through Compose item rows, which the fork now decorates too --
  titles, thumbnails and the toggle badge all behave as they do in the classic UI.
- **Replacement thumbnails** on lists and video detail. The original is always kept until a DeArrow
  frame actually loads, so a not-yet-generated frame never leaves a blank thumbnail.
- **Interactive toggle badge** — a star on each thumbnail flips that row between the DeArrow and the
  original title + thumbnail; replaced titles can also be marked with a small icon.
- **Settings -> DeArrow**: enable DeArrow, replace titles, auto-format titles, mark replaced titles,
  replace thumbnails, and "use random video frames" (random-frame fallback for videos with no
  community submission; off by default — a random frame is often less representative than the
  channel's own thumbnail), plus **clear the DeArrow cache** and links to the DeArrow site &
  privacy policy. Changing any of these takes effect on what is **already on screen**, rather than
  only on the next time a row is rebuilt.
- **Searchable replacements** — the filter box in playlists, watch history, and the subscription
  feed matches the DeArrow title a row is showing as well as the original stored one, so typing
  what you can see finds it.
- **Persistent two-tier cache** (memory -> on-disk, survives restart) with stale-while-revalidate,
  404-only negative caching, bounded transient retries, rate-limit backoff, and ahead-of-bind
  prefetching. Independent of the image cache: *Settings -> Advanced -> Download thumbnails* clears
  thumbnails only and no longer discards downloaded DeArrow titles.
- **Polite to the DeArrow API.** Every request to the single volunteer-run host goes through one of
  two fixed thread pools -- 3 for what a visible row is waiting on, 1 low-priority for background
  revalidation -- so no scroll, page load or cold start can burst it. Refreshing a stale bucket
  sends `If-None-Match`, so an unchanged bucket costs a few hundred bytes of headers instead of
  re-downloading ~17 KB. Requests are k-anonymous (hash-prefix buckets, no cookies) and identify
  the app by User-Agent.

### Instant video detail page
- Tapping a video from the feed, search, history, or a playlist renders the **thumbnail, title,
  channel, duration, and view count immediately** from the item you tapped, instead of a blank page
  for ~2 s while the full video info loads. The description, related videos, comments, and play
  controls fill in as soon as the fetch returns.

### Build, packaging & release
- **Nix toolchain** for reproducible builds and a one-command signed release (see *Building &
  installing* below): `nix run .#build` / `.#debug` / `.#install`.
- **Installs alongside** the official app — distinct `applicationId` and **PipePipeD** app name.
- **Signed GitHub Actions release** (`workflow_dispatch`, keystore via repo secrets) with parallel
  debug+release builds and an auto-generated commit changelog.
- **Single universal APK** (no per-ABI splits), **R8 disabled** on the fork release, and Gradle
  build-cache stabilization for faster, more predictable CI.

### Project layout
- Fork-only submodules: the app (`PipePipeClient`) tracks this fork's `patch` branch; the extractor
  (`PipePipeExtractor`) stays pinned to upstream. Only what we change is forked.
- Currently tracking upstream **v5.3.1**. Keeping current is a documented procedure --
  see [`docs/upstream-sync-runbook.md`](docs/upstream-sync-runbook.md).

## Building & installing (PipePipeD fork)

This fork builds via a reproducible Nix flake (Android SDK 37 + Temurin JDK 25, pinned). Clone
recursively, check out `patch`, and run the commands below from the meta-repo root with submodules
checked out (`git submodule update --init PipePipeClient PipePipeExtractor`):

| Command | What it does |
| --- | --- |
| `nix run .#build` | Build the **signed release** universal APK (PipePipeD identity). Signs when the `KEY_PATH` / `KEY_STORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD` environment variables are all set; otherwise emits an unsigned release. |
| `nix run .#debug` | Build a debug-key-signed APK for fast local iteration. |
| `nix run .#install` | Install the already-built APK(s) onto a connected ADB device. |
| `nix develop` | Drop into a dev shell with the toolchain on `PATH`. |

APKs land in `PipePipeClient/app/build/outputs/apk/{release,debug}/`.

**`nix run .#install`** does not build — run `.#build` and/or `.#debug` first. It installs the
newest APK from each of the release and debug output dirs (whichever variant(s) are present) via
`adb install -r` (reinstall, keeps app data). With multiple devices connected, pick one with
`ANDROID_SERIAL=<serial>` (`adb devices` lists them). Extra flags are forwarded to `adb install`,
e.g. `nix run .#install -- -g` (grant runtime permissions) or `nix run .#install -- -d` (allow a
version downgrade).

A fresh clone:

```sh
git clone --recursive git@github.com:HritwikSinghal/PipePipe.git
cd PipePipe && git checkout patch && git submodule update --init
nix run .#build          # first run ~10-40 min (downloads the toolchain)
```

---

<hr>
<p align="center"><img src="assets/logo.png" width="150"></p> 
<h2 align="center"><b>PipePipe (upstream)</b></h2>
<h4 align="center">
NewPipe, reimagined: faster, more stable, and packed with more features.</h4>
<p align="center"><a href="https://f-droid.org/packages/InfinityLoop1309.NewPipeEnhanced/"><img src="https://fdroid.gitlab.io/artwork/badge/get-it-on.png" alt="Get it on F-Droid"  width="207" /></a>
<a href="https://apt.izzysoft.de/fdroid/index/apk/InfinityLoop1309.NewPipeEnhanced"><img src="assets/IzzyOnDroid.png" alt="Get it on IzzyOnDroid" width="207" /></a></p>
<hr>

## Beyond NewPipe

#### YouTube Enhancements
* Integrate SponsorBlock for skipping sponsored segments (YouTube & BiliBili) 
* Restore YouTube dislikes with ReturnYouTubeDislike 
* Show original titles on YouTube (non-localized) 
* Log in to access restricted or premium content 

#### Media Features
* Display live chats in danmaku-style overlays
* Support AV1 and VP9 codecs for efficient, high-quality playback 
* Enable music player mode with background playback 

#### Filtering
* Apply advanced search filters for better discovery 
* Filter out unwanted items by keywords or channels 
* Block shorts and paid videos for a cleaner feed 

#### Playback Controls
* Use swipe-to-seek and fullscreen gestures for intuitive navigation 
* Long-press to speed up playback 
* Set a sleep timer for bedtime listening 

#### Enhanced Playlists
* Download full playlists at once 
* Search and sort within local playlists and histories

... and many more improvements!


## Screenshots

[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/00-v2.png" width=640>](fastlane/metadata/android/en-US/images/phoneScreenshots/00-v1.png)

[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/01-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/01-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/02-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/02-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/03-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/03-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/04-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/04-v3.png)
<br/>
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/05-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/05-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/06-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/06-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/07-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/07-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/08-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/08-v3.png)
<br/>
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/09-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/09-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/10-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/10-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/11-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/11-v3.png)
[<img src="fastlane/metadata/android/en-US/images/phoneScreenshots/12-v3.png" width=160>](fastlane/metadata/android/en-US/images/phoneScreenshots/12-v3.png)


## About this fork

Due to differences in development philosophy, I forked NewPipe in early 2022 and began independent development based on it.

This means that PipePipe neither receives updates from NewPipe nor pushes updates to NewPipe. They have become two separate projects. Issues that occur in NewPipe don't necessarily happen in PipePipe, and changes made in NewPipe may not be adopted by PipePipe. In contrast, forks like Tubular track the latest version of NewPipe and develop based on it.

Making a hard fork allows us to effectively address issues with quick fixes and maintain frequent feature updates.

## About sign in

PipePipe will ONLY use the login cookie for the specified scenarios you set. You can configure it in "Cookie Functions."

For YouTube, the cookie will only be used when retrieving playback streams.

## Contribute

Issues and PRs are welcomed. Please note that I will **NOT** accept service requests. 

Anyone interested in creating their own service is encouraged to fork this repository.

## Donation

If you find PipePipe useful, please consider becoming a supporter on Ko-Fi. Your support is important to me and helps me add more exciting new features. Every bit counts!

Liberapay: https://liberapay.com/PipePipe

Ko-fi: https://ko-fi.com/pipepipe

## Community

[PipePipe Wiki](https://priveetee.github.io/Docs-PipePipe) maintained by [@Priveetee](https://github.com/Priveetee)

## Special Thanks

[Priveetee](https://github.com/Priveetee) for [researching SABR](https://priveetee.github.io/Docs-PipePipe/developer-guide/introduction.html) and implementing support for it.

[AioiLight](https://github.com/AioiLight) for providing some code of NicoNico service.
