# Upstream sync runbook (PipePipeD)

How to move this fork onto a new upstream PipePipe release and publish a signed
PipePipeD APK. Written to be followed top-to-bottom by someone (or some agent)
with no memory of the previous sync.

**Read this first, then `docs/progress.md`** for where the last sync stopped.

## 0. Mental model

PipePipe is a **thin meta-repo**; the app lives in submodules.

| Repo | Fork? | Our branch | Base |
|---|---|---|---|
| `PipePipe` (meta) | yes, `HritwikSinghal/PipePipe` | `patch` (default branch) | `upstream/main` |
| `PipePipeClient` | yes, `HritwikSinghal/PipePipeClient` | `patch` (default branch) | `upstream/dev` |
| `PipePipeExtractor` | **no** -- dormant, upstream-pinned | -- | -- |
| `PipePipe.wiki` | **no** -- never initialized | -- | -- |

The meta-repo `patch` branch owns only: `flake.nix`, `flake.lock`,
`.github/workflows/{ci,release}.yml`, `README.md`, `docs/`, `CLAUDE.md`,
`.gitmodules`, `.gitignore`, and the submodule gitlinks. Everything else is
upstream's.

Two invariants that shape every step below:

- **Additive-only fork edits.** Every fork change to `PipePipeClient/app/build.gradle`
  is an end-of-file block that reconfigures `android { }` *after* upstream's DSL.
  With the `-Pfork*` properties absent, upstream's build is byte-for-byte
  unchanged. Never edit upstream's `versionCode` / `versionName` / `splits` /
  `buildTypes` lines in place -- that is what keeps the rebase conflict-free.
- **Client before meta.** Always push the client `patch` **before** the meta
  gitlink bump, or a recursive clone in the window between cannot resolve the
  gitlink.

## 1. Preflight

```sh
cd ~/Projects/PipePipe
git fetch upstream --tags
git -C PipePipeClient fetch upstream --tags
# Every initialized submodule, whatever its remote layout (see 3a -- the extractor
# has only `origin`, and it points at upstream). Tolerant of missing remotes.
git submodule foreach 'git fetch --all --tags || true'
git status --short                       # must be clean
git submodule status
```

Bring `main` up to upstream (this should be a fast-forward; if it is not, stop
and find out why):

```sh
git checkout main && git merge --ff-only upstream/main && git checkout patch
```

Record the release target and the three pins:

```sh
git log --oneline -1 main                            # meta target, e.g. efdaf4e v5.2.5
git ls-tree main | grep PipePipe                     # upstream's client + extractor pins
git log --oneline -1 PipePipeClient                  # our current client tip
```

Upstream's client pin at the meta tag is normally the same commit as
`upstream/dev`'s tip. **Rebase the client onto the pin the meta tag names**, not
onto whatever `upstream/dev` happens to be at -- they diverge as soon as
upstream starts the next beta.

Tag rollback points in **both** repos (`git tag` needs `-m` here; see Gotchas):

```sh
V=<new-upstream-version>          # e.g. 5.2.5
git tag -m "Pre-rebase backup before upstream v$V sync" backup/pre-rebase-$V patch
git -C PipePipeClient tag -m "Pre-rebase backup before upstream v$V sync" backup/pre-rebase-$V patch
```

## 2. Triage the upstream diff BEFORE rebasing

This is the step that catches the silent breakages. A clean rebase does **not**
mean a working fork: upstream can refactor code our additive blocks and our CI
*read*, and git will report no conflict at all.

### 2a. Did the toolchain move?

```sh
git -C PipePipeClient diff <old-client-pin>..<new-client-pin> -- \
  build.gradle settings.gradle gradle.properties gradle/wrapper/gradle-wrapper.properties
```

- **Empty diff** -> `flake.nix` needs no change. Go on.
- **Non-empty** -> read it. Plugin versions live in `settings.gradle`
  `pluginManagement` (there is no root `build.gradle` on the 5.2.x line). A move
  in AGP / Gradle / Kotlin / JDK / `compileSdk` means updating `flake.nix`:
  `jdk`, `platformVersions`, `buildToolsVersions`, `aapt2BuildTools`. Take
  `gradle.properties` from upstream wholesale.

### 2b. Did upstream refactor anything our additive blocks depend on?

```sh
git -C PipePipeClient diff <old-client-pin>..<new-client-pin> -- app/build.gradle
```

Our end-of-file blocks hook four things. For each, confirm the mechanism still
exists and still feeds the output:

| Fork property | Hooks | Breaks if upstream... |
|---|---|---|
| `-PforkVersionName` / `-PforkVersionCode` | APK filename, `output.versionCode`, `BuildConfig.VERSION_CODE` | ...stops reading `android.defaultConfig.*` in its `androidComponents.onVariants` closure |
| `-PforkAbiFilter` | `android.splits.abi` | ...replaces the `splits { abi { } }` DSL |
| `-PforkMinify` | `android.buildTypes.release.minifyEnabled` | ...moves minification out of `buildTypes` |
| applicationId / app_name | `android.defaultConfig.applicationId`, `resValue "string", "app_name"` | ...renames or restructures the variant blocks |

> **Precedent (v5.2.5).** Upstream hoisted versioning into script-local
> `def baseVersionCode` / `def appVersionName` / `def abiCodes` /
> `stableBuildConfigVersionCode` and made its `onVariants` closure read *those*
> instead of `android.defaultConfig`. Our version override still set
> `defaultConfig`, so it kept feeding the manifest but no longer reached the APK
> filename, `output.versionCode`, or the new `BuildConfig.VERSION_CODE` field.
> Zero conflicts; wrong release. The fix -- and the pattern to prefer -- is for
> the fork block to register **its own** `androidComponents.onVariants` and
> re-derive everything from the fork properties, rather than depending on how
> upstream computed its values.

### 2c. Does `release.yml` still parse upstream's version?

`.github/workflows/release.yml` reads upstream's base version by **grepping**
`PipePipeClient/app/build.gradle`. Re-verify the greps against the new file:

```sh
GRADLE_FILE=PipePipeClient/app/build.gradle
grep -E '^[[:space:]]*(def[[:space:]]+baseVersionCode[[:space:]]*=|versionCode[[:space:]]+[0-9])' "$GRADLE_FILE"
grep -E '^[[:space:]]*(def[[:space:]]+appVersionName[[:space:]]*=|versionName[[:space:]]+")' "$GRADLE_FILE"
```

Both must print exactly one useful line. If either comes back empty the workflow
must be fixed *before* the release is triggered -- an unmatched grep yields an
empty `BASE_CODE`, and bash evaluates `$((BASE_CODE + RUN_NUMBER))` with an empty
operand as `0 + RUN_NUMBER`, so the release publishes `versionCode` = run number
(a two-digit number). That is lower than the installed build, so the APK silently
stops being an in-place update. The workflow now hard-fails on an empty parse;
keep that guard.

### 2d. How big is the conflict surface?

```sh
comm -12 \
  <(git -C PipePipeClient diff --name-only <old-client-pin>..<our-tip> | sort) \
  <(git -C PipePipeClient diff --name-only <old-client-pin>..<new-client-pin> | sort)
```

That is the exact set of files both sides touched -- the only possible conflicts.
Most fork files are new DeArrow files and never conflict.

## 3. Rebase the client fork

```sh
cd PipePipeClient
git checkout patch
git rebase --onto <new-client-pin> <old-client-pin> patch
```

Resolve conflicts with these rules:

- **DeArrow hook sites** (`InfoListAdapter`, `StreamInfoItemHolder`,
  `StreamMiniInfoItemHolder`, `LocalItemListAdapter`, `StreamItem.kt`,
  `PlayQueueItemBuilder`, `VideoDetailFragment`, `InfoItemDialog`, `Player`,
  `BaseListFragment`, `FeedFragment.kt`, `NavigationHelper`): keep upstream's
  logic, re-apply our call into `DeArrowItemController` / `DeArrowPrefetcher` on
  top. Never mutate extractor models; never overwrite
  `VideoDetailFragment.title` (share / notification / history read it).
- **`strings.xml`, `settings_keys.xml`, `ids.xml`**: take upstream's block, append
  ours. Translations (`values-*/strings.xml`) are upstream-only -- take theirs.
- **`app/build.gradle`**: take upstream's body wholesale, keep our end-of-file
  blocks, then apply whatever 2b turned up.
- **`.gitignore`, `gradle.properties`**: take upstream, re-add our lines.

Then confirm nothing was dropped:

```sh
git log --oneline <new-client-pin>..HEAD          # expect our N fork commits, no more
git grep -l "DeArrow" -- app/src/main | wc -l     # compare against pre-rebase count
git diff <our-old-tip> HEAD -- app/src/main/java/org/schabi/newpipe/util/dearrow/
```

The last one should be empty or trivially small -- the DeArrow package is ours
alone, so upstream churn must not have altered it.

### 3a. Sync EVERY other submodule to upstream's new pins

**Do not skip this, and do not assume the client is the only submodule that
moved.** Upstream's release tag records a pin for *every* submodule, and they
advance together. Sync them all -- driven off the pins in `main`, not off a
hand-maintained list, so a submodule upstream adds later is picked up
automatically.

List every gitlink upstream's target records, next to what is checked out now:

```sh
git ls-tree main | awk '$2=="commit" {print $3, $4}'   # upstream's pins
git submodule status                                   # what is checked out
```

Then, for each submodule **except the forked `PipePipeClient`** (which gets the
rebase in section 3 instead of a pin adoption), adopt upstream's pin:

```sh
git -C <path> status --porcelain          # must be clean before moving it
git -C <path> checkout --detach <pin-from-main>
```

A detached HEAD is normal and expected for these -- they are dormant and unforked,
so we track upstream's exact commit and never carry work on them.

Do **not** shortcut this with `git submodule update --init` while our branch is
checked out: that resolves gitlinks from the index, which would drag
`PipePipeClient` back to whatever commit is pinned there and discard the rebase.
Sync the unforked submodules to `main`'s pins, and set the client gitlink
explicitly (section 5).

**Why this is load-bearing, not hygiene.** `PipePipeExtractor` is wired in as a
Gradle **composite build** (`includeBuild('../PipePipeExtractor')`), so the app
compiles against the extractor's **checked-out working tree**, not a published
artifact. A new-client / old-extractor pair fails with a symbol that does not
exist yet -- which reads like a botched rebase but is really a stale submodule:

```
kaptDebugKotlin FAILED
  .../LocalDomPoTokenProvider.java:31: error: cannot find symbol
  symbol: class YoutubeSessionPoTokenProvider
```

(Real failure from the v5.2.5 sync: client at v5.2.5, extractor still at
v5.2.3-beta.)

`PipePipe.wiki` has never been initialized and is not part of the build, so it
needs no checkout -- but its gitlink still has to match upstream's, which it does
automatically once our branch is based on `main`. Leave it uninitialized.

Note the remotes here are inconsistent: `PipePipeExtractor` has **no `upstream`
remote at all** -- its `origin` *is* upstream's HTTPS URL (there is no extractor
fork; it was deleted). `PipePipeClient` has both (`origin` = our fork,
`upstream` = upstream). So `git -C PipePipeExtractor fetch upstream` fails; the
pins are normally already present locally from the meta fetch. Confirm a pin
exists before checking it out:

```sh
git -C <path> log --oneline -1 <pin>
```

## 4. Verify the build

Both commands run from the **meta-repo root**:

```sh
cd ~/Projects/PipePipe
nix run .#debug                       # single universal debug APK
nix develop -c bash -c 'cd PipePipeClient \
  && ./gradlew :app:testDebugUnitTest --tests "org.schabi.newpipe.util.dearrow.*"'
```

Do **not** `cd PipePipeClient` before `nix develop`: the submodule is its own git
repo, so nix stops its upward flake search at that boundary and fails with "is
not part of a flake". Enter the dev shell from the root and `cd` inside it. (The
dev shell exports `JAVA_HOME`, `ANDROID_HOME`, and the `aapt2` override; `sdk.dir`
in `PipePipeClient/local.properties` is written by `nix run .#debug`, so run the
build at least once before the tests on a fresh checkout.)

All DeArrow unit tests must pass (**106** as of v5.3.1). Count them from the XML
rather than trusting the console: every class must appear *and* its executed
count must equal its `@Test` count, or a class silently stopped running.

```sh
cd PipePipeClient/app/build/test-results/testDebugUnitTest
grep -ho 'tests="[0-9]*"' TEST-org.schabi.newpipe.util.dearrow.*.xml
```

Checkstyle is **not** in `assembleDebug` and **not** a CI gate, and upstream
itself fails it -- hand-check any new file for the 100-column limit, `final`
params, unused imports, and a trailing newline.

`nix run .#build` produces the signed release APK, `nix run .#install` pushes to
an ADB device.

Also re-prove the fork versioning override end to end -- it is the mechanism that
broke silently in the v5.2.5 sync, and a plain `.#debug` passes no fork
properties, so it does **not** exercise it:

```sh
nix run .#debug -- -PforkVersionName=<newver>-pipepiped.999 -PforkVersionCode=<baseVersionCode>
cat PipePipeClient/app/build/outputs/apk/debug/output-metadata.json
grep -E 'VERSION_CODE|VERSION_NAME|APPLICATION_ID' \
  PipePipeClient/app/build/generated/source/buildConfig/debug/org/schabi/newpipe/BuildConfig.java
```

Expect `applicationId wtf.pipepiped.debug`, `versionCode` = 100 x forkVersionCode,
`BuildConfig.VERSION_CODE` = that + 1 (upstream's ABI-stable armeabi-v7a
semantic), and the fork versionName in both the metadata and the APK filename.

### 4a. Audit the DeArrow hook sites

**A compile-clean, test-green rebase does not mean DeArrow still works.** Git
merges our hook into a method upstream may have stopped calling, and neither the
compiler nor a unit test notices -- the same silent class of failure as 2b. After
every sync, confirm all five:

```sh
cd PipePipeClient
# 1. our package is untouched by upstream churn (must be empty)
git diff <our-old-tip> HEAD -- app/src/main/java/org/schabi/newpipe/util/dearrow/ \
                               app/src/test/java/org/schabi/newpipe/util/dearrow/
# 2. every bind/dispose call still exists (note the lowercase field name --
#    grepping "DeArrow" alone misses `deArrowController.apply(...)`)
grep -rn "deArrowController\.\|deArrowMatcher\|DeArrowPrefetcher\.prefetch" app/src/main/java
# 3. upstream must not have touched our badge-carrying layouts; all must still
#    declare dearrow_badge
comm -12 <(git diff --name-only <new-pin>..HEAD -- 'app/src/main/res/layout*' | sort) \
         <(git diff --name-only <old-pin>..<new-pin> -- 'app/src/main/res/layout*' | sort)
grep -rln "dearrow_badge" app/src/main/res/layout*      # expect 6
# 4. the settings screen is still linked from its parent
grep -rn "dearrow" app/src/main/res/xml/main_settings.xml
# 5. no new upstream surface DeArrow would miss
git diff --diff-filter=A --name-only <old-pin>..<new-pin> -- app/src/main/java | grep -iE 'holder|adapter'
```

For each `apply()` call, open the enclosing method and confirm upstream still
calls it. The ones that matter: `VideoDetailFragment.handleResult`,
`Player`'s metadata/title path, `PlayQueueActivity.onMetadataUpdate`, the four
item holders' `updateFromItem`, `PlayQueueItemBuilder`, `StreamItem.kt`, and both
adapters' prefetch + recycle-dispose.

Known and **not** a regression: the experimental Compose item holders
(`ComposeInfoItemHolder`, `ComposeLocalItemHolder`) are DeArrow-blind, and the
prefetch is deliberately skipped under `shouldUseExperimentalNewUi`. Re-check
each sync that upstream has not made that UI the default.

## 5. Rebase the meta repo

The meta diff is usually tiny and barely overlaps ours (upstream-only workflow
files and `fastlane/metadata/.../changelogs/*.txt`, plus the gitlinks). A literal
rebase works when our history is already clean:

```sh
cd ~/Projects/PipePipe
git rebase --onto main <old-meta-base> patch
```

If our history carries throwaway churn (gitlink bumps, add-then-delete pairs)
the literal rebase stops on conflicts that are pure noise. In that case
**direct-construct** instead -- branch off `main`, `git checkout <old-tip> -- <paths>`
per logical commit group, hand-merge the one or two genuinely shared files, then
`git branch -f patch <new-tip>`. Aim for the same small set of logical commits
each time: `build(nix)` / `ci(release)` / `docs`.

Re-pin the submodules. Basing on `main` already adopts upstream's pins for the
dormant ones, so in practice only the client gitlink needs setting -- to the tip
of the rebase from section 3. Stage it from the submodule's actual HEAD:

```sh
git -C PipePipeClient rev-parse HEAD    # sanity-check what you are about to pin
git add PipePipeClient                  # stages the submodule's current HEAD
git ls-files -s PipePipeClient          # confirm the gitlink
```

Prefer `git add <path>` over `git update-index --cacheinfo 160000,<sha>,<path>`.
`--cacheinfo` **cannot validate a gitlink**, because the commit lives in another
repository -- it silently accepts a SHA that does not exist anywhere, and the
result is a branch that no recursive clone can resolve. If you do use it, never
hand-type or guess the SHA: derive it with `git -C <path> rev-parse HEAD` and
verify with `git ls-files -s <path>` afterwards.

Verify byte-faithfulness with two diffs that must both be empty:

```sh
# A: nothing outside the fork-owned set changed -- must print nothing
git diff main patch --name-only | grep -vE \
  '^(flake\.nix|flake\.lock|\.github/workflows/(ci|release)\.yml|README\.md|docs/|CLAUDE\.md|\.gitmodules|\.gitignore|PipePipeClient|PipePipeExtractor)'
# B: our own content survived
git diff <old-meta-tip> patch -- flake.nix flake.lock .github CLAUDE.md .gitmodules .gitignore
```

The first proves we dropped nothing of upstream's; the second proves our own
content survived. Filter A by the **fork-owned set from section 0**, not by
`ls-tree main | grep -v README.md|<gitlinks>` as this file said until the v5.3.1
sync: that older form also lists `.github/`, `.gitignore`, `.gitmodules` and
`flake.*`, which we own and *expect* to differ, so a correct rebase reads as a
failure. `README.md` and `docs/` are excluded from A because we rewrote them --
diff those by hand.

## 6. Update the docs

- **`README.md`, "PipePipeD -- changes from upstream"**: required by `CLAUDE.md`
  whenever a change alters how the fork differs from upstream -- a user-facing
  feature, a setting, or a build / packaging / release change. Toolchain and
  signing changes count.
- **`docs/progress.md`**: rewrite `## Current state` and `## Next actions` in
  place (do not add a second section describing the same thing), append one line
  to `## Decisions (durable)` and one paragraph to `## Session log`.
- **This runbook**: if any step above was wrong or incomplete, fix it now, while
  the detail is fresh. That is the whole point of the file.

## 7. Push and release

Client first, then meta (the invariant from section 0). A rebase rewrites
history, so both need `--force-with-lease`. **The agent cannot force-push --
the user runs these:**

```sh
git -C PipePipeClient push --force-with-lease origin patch
git push --force-with-lease origin patch
```

Then trigger the release (`workflow_dispatch` on `patch`):

```sh
gh workflow run release.yml --ref patch
gh run watch
```

The workflow computes `versionName = <upstream version>-pipepiped.<run_number>`
and `versionCode = <upstream base> + run_number`, builds one universal APK per
variant with `-PforkAbiFilter=universal -PforkMinify=false`, and publishes a
GitHub Release tagged `pipepiped-v<versionName>`.

Confirm before calling it done:

- Job `build-release` green, including **`Verify release APK is signed`**
  (upstream's build signs *silently unsigned* if any `KEY_*` env var is missing;
  the workflow has a pre-build secret guard and a post-build `apksigner verify`
  precisely because a missing secret is otherwise invisible).
- The published `versionCode` is greater than the previous release's, and
  `versionName` carries the new upstream version.
- On-device: the APK **updates the existing `wtf.pipepiped.release` install in
  place** (proves the signature is stable), then smoke-test DeArrow titles and
  thumbnails across list / feed / history / detail / player / queue, plus SABR
  playback.

## Gotchas

Durable traps, all of them hit at least once:

- `commit.gpgsign` and `tag.gpgsign` are **on**. `git tag` must be annotated
  (`-m`). `git rebase -i` is unavailable in this environment -- to reword a
  non-tip commit, detach, `commit --amend -F <file>`, `cherry-pick` the rest,
  `git branch -f`.
- A `commit --amend` reporting "would make it empty" means that content is
  already folded elsewhere -- drop the commit with `git reset --soft HEAD^`.
- The `clean_commit_guard` hook **blocks any shell command containing the
  substring "claude"**. Write commit-message files for `-F` to a path without it,
  and keep the token out of commit messages.
- Force-push is blocked for the agent. Hand the user the exact command.
- A stale `PipePipeClient/local.properties` `sdk.dir` (a garbage-collected Nix
  store path from an older toolchain) shadows `ANDROID_HOME` and fails the build
  with "Directory does not exist". `flake.nix` now rewrites `sdk.dir` on
  mismatch.
- The keystore is **never** committed (public repo). CI decodes it from the
  `KEYSTORE_*` secrets; local release builds use a gitignored auto-generated
  keystore. Backups live at `~/.pipepipe-fork-keystore/`. PKCS12 requires
  store password == key password, or signing fails with "final block not
  properly padded".
- There is **no NDK** in the flake: `:ffmpeg` ships a prebuilt `ffmpeg-kit.aar`
  with native libs for `arm64-v8a` and `x86_64` only -- which is why a single
  universal APK loses nothing versus upstream's per-ABI splits.
- An `emoji_remover` hook strips emoji from written files, and edits to a file
  containing pre-existing emoji get flagged. Do not introduce new emoji; do not
  strip upstream's.

## Sync history

| Date | From | To | Client drift | Notes |
|---|---|---|---|---|
| 2026-07-09 | v5.1.1 | v5.2.3-beta | 169 commits | Major toolchain jump: Gradle 7.5 -> 9.5.1, AGP 7.3 -> 9.2.1, Kotlin 1.7 -> 2.3.21, JDK 11 -> 25, compileSdk 33 -> 37, minSdk 21 -> 23. Adopted upstream's env-var signing, dropped the fork `keystore.properties`. Only hard merge: `NavigationHelper.java`. |
| 2026-08-08 | v5.2.3-beta | v5.2.5 | 107 commits | No toolchain change. Upstream's `onVariants` versioning refactor silently broke the `-PforkVersion*` override and `release.yml`'s version greps (see 2b, 2c) -- both found by diff triage, not by conflicts. A stale extractor pin then broke the build (see 3a). Released `pipepiped-v5.2.5-pipepiped.13`. |
| 2026-09-11 | v5.2.5 | v5.3.1 | 47 commits | No toolchain change; the 2b/2c hooks all survived, so the triage found nothing to fix. Upstream reverted **media3 -> ExoPlayer 2.18.7** with its SABR rewrite, rewriting `Player.java` (+245/-224) -- our 4 anchor lines re-merged cleanly and no fork file references media3. 3 trivial conflicts. The extractor pin moved `aa72c976` -> `c0cd0d61`. Follow the DeArrow hook audit in step 4a: a compile-clean rebase says nothing about a hook stranded off a live path. |

Push the backup tags to both remotes before force-pushing, not just locally: the
force-push is what makes the old remote history unreachable, so a tag that exists
only on your machine is not much of a rollback point.

```sh
git -C PipePipeClient push origin refs/tags/backup/pre-rebase-<V>
git push origin refs/tags/backup/pre-rebase-<V>
```
