<hr>
<p align="center"><img src="assets/logo.png" width="150"></p> 
<h2 align="center"><b>PipePipe</b></h2>
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

## PipePipe+ — changes from upstream

**PipePipe+** is a personal, signed fork of PipePipe that adds **DeArrow** support and a reproducible
Nix/CI **signed-release** pipeline. It installs **alongside** the official app (distinct application
ID with a `.plus` suffix, app name "PipePipe+") and tracks upstream `InfinityLoop1308/PipePipe`,
staying current by rebasing. Everything in this section is what differs from upstream; the rest of
this README is upstream's.

> Maintainers: keep this list in sync with `docs/progress.md` whenever fork behavior changes
> (see `CLAUDE.md`).

### DeArrow — crowdsourced de-clickbait titles & thumbnails (YouTube)
- **Replacement titles** from the DeArrow community on every surface: feed/lists, video detail, the
  player, the now-playing queue, and info dialogs. Optional auto-formatting of SHOUTING titles.
- **Replacement thumbnails** on lists and video detail. The original is always kept until a DeArrow
  frame actually loads, so a not-yet-generated frame never leaves a blank thumbnail.
- **Interactive toggle badge** — a star on each thumbnail flips that row between the DeArrow and the
  original title + thumbnail; replaced titles can also be marked with a small icon.
- **Settings -> DeArrow**: enable DeArrow, replace titles, auto-format titles, mark replaced titles,
  replace thumbnails, and "use random video frames" (random-frame fallback for videos with no
  community submission; off by default — a random frame is often less representative than the
  channel's own thumbnail), plus links to the DeArrow site & privacy policy.
- **Persistent two-tier cache** (memory -> on-disk, survives restart) with stale-while-revalidate,
  404-only negative caching, bounded transient retries, and ahead-of-bind prefetching.

### Instant video detail page
- Tapping a video from the feed, search, history, or a playlist renders the **thumbnail, title,
  channel, duration, and view count immediately** from the item you tapped, instead of a blank page
  for ~2 s while the full video info loads. The description, related videos, comments, and play
  controls fill in as soon as the fetch returns.

### Build, packaging & release
- **Nix toolchain** for reproducible builds and a one-command signed release (see *Building &
  installing* below): `nix run .#build` / `.#debug` / `.#install`.
- **Installs alongside** the official app — distinct `applicationId` and **PipePipe+** app name.
- **Signed GitHub Actions release** (`workflow_dispatch`, keystore via repo secrets) with parallel
  debug+release builds and an auto-generated commit changelog.
- **Single universal APK** (no per-ABI splits), **R8 disabled** on the fork release, and Gradle
  build-cache stabilization for faster, more predictable CI.

### Project layout
- Fork-only submodules: the app (`PipePipeClient`) tracks this fork's `patch` branch; the extractor
  stays pinned to upstream. Only what we change is forked.

## Building & installing (PipePipe+ fork)

This fork builds via a reproducible Nix flake (Android SDK 33 + JDK 11, pinned). Run the commands
below from the meta-repo root with submodules checked out
(`git submodule update --init PipePipeClient PipePipeExtractor`):

| Command | What it does |
| --- | --- |
| `nix run .#build` | Build the **signed release** universal APK (PipePipe+ identity). Signs when `PipePipeClient/keystore.properties` is present; otherwise emits an unsigned release. |
| `nix run .#debug` | Build a debug-key-signed APK for fast local iteration. |
| `nix run .#install` | Install the already-built **release** APK onto a connected ADB device. |
| `nix develop` | Drop into a dev shell with the toolchain on `PATH`. |

APKs land in `PipePipeClient/app/build/outputs/apk/{release,debug}/`.

**`nix run .#install`** does not build — run `.#build` first. It installs the newest APK in the
release output dir via `adb install -r` (reinstall, keeps app data). With multiple devices
connected, pick one with `ANDROID_SERIAL=<serial>` (`adb devices` lists them). Extra flags are
forwarded to `adb install`, e.g. `nix run .#install -- -g` (grant runtime permissions) or
`nix run .#install -- -d` (allow a version downgrade).

## About sign in

PipePipe will ONLY use the login cookie for the specified scenarios you set. You can configure it in "Cookie Functions."

For YouTube, the cookie will only be used when retrieving playback streams.

## Contribute

Issues and PRs are welcomed. Please note that I will **NOT** accept service requests. 

Anyone interested in creating their own service is encouraged to fork this repository.

## Donation

If you find PipePipe useful, please consider becoming a supporter on Ko-Fi. Your support is important to me and helps me add more exciting new features. Every bit counts! 😇

Liberapay: https://liberapay.com/PipePipe

Ko-fi: https://ko-fi.com/pipepipe

## Community

[PipePipe Wiki](https://priveetee.github.io/Docs-PipePipe) User wiki maintained by [@Priveetee](https://github.com/Priveetee)

## Special Thanks

[SocialSisterYi/bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect) for providing some BiliBili API lists.

[AioiLight](https://github.com/AioiLight) for providing some code of NicoNico service.
