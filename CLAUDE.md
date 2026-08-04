# CLAUDE.md

Guidance for Claude Code working in this repository.

Kazumi is a Flutter anime streaming client that scrapes third-party video sites
through user-installable rule "plugins". **This checkout is a desktop-only fork**
(`BoyuanZhangDE/Kazumi`) of upstream `Predidit/Kazumi`. Mobile is out of scope —
do not spend effort on Android/iOS concerns.

## Toolchain

**Flutter is not on PATH.** Every command must be prefixed:

```bash
export PATH="$HOME/develop/flutter/bin:$PATH"
```

Flutter 3.44.8 stable, pinned via `environment: flutter:` in `pubspec.yaml`.
Forgetting the prefix produces `command not found` and, historically, whole
rounds of work shipped unverified. CocoaPods (required for macOS builds) is at
`/opt/homebrew/bin/pod`.

## Architecture

- **DI + routing:** `flutter_modular`. Page-scoped controllers are bound per
  route — reach them with `context.read<T>()` from inside the page subtree, not
  the global `inject<T>()`.
- **State:** MobX with codegen. After editing `@observable`/`@action` in a
  controller, regenerate: `dart run build_runner build --delete-conflicting-outputs`.
  The `.g.dart` files are committed.
- **Storage:** Hive behind `GStorage` (`lib/services/storage/storage.dart`).
  Boxes: `histories`, `collectibles`, `favorites`, `downloads`, `setting`, …
  Prefer storing a JSON string under a `SettingsKeys` entry over adding a new
  Hive `TypeAdapter` — adapters require codegen, JSON does not.
- **UI language:** user-facing strings are Chinese, written inline (no ARB/i18n
  layer). Match the tone of surrounding strings.

### Playing a video is a three-stage chain

This is the single most important thing to understand before touching playback.

| Stage | Call | Cost | Proves |
|---|---|---|---|
| 1. Search | `plugin.queryBangumi(keyword)` | HTTP, parallel across plugins | The source lists something by this name |
| 2. Chapters | `plugin.queryChapterRoads(src)` | HTTP + parse | Episode list and 播放线路 exist |
| 3. Resolve | `WebViewVideoSourceService.resolve(url)` | **Headless WebView, 15–30s** | It actually plays |

Stage 3 cannot be replaced by an HTTP request. The video URL is manufactured at
runtime by the site's own obfuscated player JS; the resolver injects script that
monkey-patches `Response.prototype.text` and `XMLHttpRequest.prototype.open` to
catch the m3u8 as the page fetches it, plus intercepts `.m3u8`/`Range:` requests
and scans DOM `<video>` elements. That is why `lib/webview/video/` carries five
platform implementations. HTTP is only useful *after* resolution, to validate the
returned playlist.

**The coloured dot in the source sheet reflects stage 1 only.** A green source can
still fail to play. Two independent confirmations from live testing: DM84 returned
`522` on its homepage while its search endpoint worked fine, and sources that
resolve a URL can still serve a dead playlist.

### Plugins (scraper rules)

- Bundled: `assets/plugins/*.json` (3). User-installed live in the app support
  dir (`…/plugins/v2/plugins.json`) — this machine has 13.
- `Plugin.fromJson`; rules run in either XPath or API mode (`searchMode`/`chapterMode`).
- Sources break constantly — dead DNS, 403, Cloudflare 522 are all normal. Code
  and tests must treat a broken source as an expected condition, never an error.

### Automatic playable-source selection

Entering a show races candidate sources instead of asking the user to pick. See
`docs/ideas/source-auto-selection.md` for the full design, rationale, and known
limits. Key invariants if you touch it:

- `VideoSourceResolverPool` **defaults to 1 worker** — you must call
  `resize(n)` or a "parallel" race silently degenerates to serial, with the extra
  candidates failing instantly as `StateError`.
- The per-show cache is an **ordering hint, never a promise**. A stale entry must
  cost ~0, not a 30s timeout. Never let a cached verdict skip the race.
- On a source swap the resume offset is **dropped to zero**. Episode numbering is
  not stable across sources (specials/OVAs, split-cour renumbering), so seeking a
  remembered position into a possibly-different episode is worse than starting over.
- An **explicit** user pick (source sheet, 片源 dropdown) is never auto-swapped
  away. A resumed history entry is a remembered default, not a pick.

## Testing

Design constraint: **units take their I/O as injected dependencies** and never
reach for a WebView, Hive, or an HTTP client directly. That is what makes this
logic testable at all — follow it for anything new.

### Three tiers

```bash
export PATH="$HOME/develop/flutter/bin:$PATH"

flutter test                                  # 183 pass + 1 skipped, zero network
flutter test --tags live --run-skipped        # real scraper sites, opt-in
flutter test integration_test/<file>.dart -d macos   # drives the real app
```

**Unit** (`test/`) — pure Dart, no network. This is what CI runs.

**Live** (`test/live/`) — hits real sources. Tagged `live` and marked `skip:` in
`dart_test.yaml`. `--run-skipped` is mandatory, not optional: dart_test's
`exclude_tags` *unions* with the CLI's exclude set and can never be undone by
`--tags`, which would make the suite permanently unreachable. These are
**diagnostic**: assert only our own invariants (a dead host surfaces as a typed
exception rather than a hang; the validator returns `false` rather than throwing).
Print remote availability, never assert on it — otherwise "the internet is broken
today" becomes a red build and people learn to ignore the suite.

**Integration** (`integration_test/`) — boots the real app on macOS via the Dart
VM service. Note OS-level UI scripting is *not* available (AppleScript/System
Events times out on an Accessibility permission prompt), so this is the only way
to drive the UI. Conventions, all learned the hard way:

- Override `PathProviderPlatform` to a temp dir and seed it by **read-only
  copying** the user's real `plugins.json`. Never write to real app data.
- **Never use `pumpAndSettle`** — several widgets animate continuously during
  network calls and it will hang. Use bounded manual pump loops.
- Reach page-scoped controllers with `context.read<T>()`.
- `flutter test` ignores `integration_test/` by default; keep it that way.

### What review catches that tests don't

Three real defects in this feature were found by reading the assembled flow, not
by any test — a straggler double-validate whose own test passed either way, a
regression from two separately-correct changes interacting, and a UI flicker
spanning two rounds of work. When a change spans files or sessions, read the whole
path, not just the diff.

A test only counts as a regression test if you've **seen it fail**. Revert the fix,
watch it go red, restore. This was done for the resume/manual-pick bug and is the
reason that test is trustworthy.

## Releasing (desktop fork)

`.github/workflows/release.yaml` is **upstream's — leave it byte-identical** so
upstream syncs merge cleanly. It cannot be used here anyway: its Windows job needs
all five other platform jobs, and its signing steps are hard-wired to upstream's
SignPath org (`organization-id: fa047255-…`), which this fork has no access to.

Use `.github/workflows/release-desktop.yaml` instead: macOS + Windows only,
unsigned, publishes a **draft** release.

```bash
git tag -a "autosource/vX.Y.Z" -m "…" && git push origin "autosource/vX.Y.Z"
```

Four traps, each of which has already cost a build cycle:

1. **Tag namespacing is load-bearing.** Upstream's workflow triggers on `"*"`,
   and GitHub's tag glob `*` does not match `/`. A tag like `autosource/v2.2.6.2`
   is therefore invisible to it. A flat tag would kick off a doomed six-platform
   build alongside ours.
2. **A slash in the tag breaks filenames.** The workflow derives a `tag_safe`
   (slashes → `-`) for artifact names, while `tag_name:` keeps the real ref.
3. **`yq` is not preinstalled on `windows-latest`.** `subosito/flutter-action`
   needs it to parse `flutter-version-file: pubspec.yaml`; without it the job
   fails at "Set up Flutter" with `yq not found`. macOS/Linux runners have it,
   which is why only Windows failed. The `choco install yq` step must not be
   pruned as clutter — that is exactly how the bug was introduced.
4. **`gh` resolves to the wrong repo.** With both `origin` and `upstream`
   configured it picks upstream. **Always pass `--repo BoyuanZhangDE/Kazumi`** —
   a `gh release create` without it targeted `Predidit/Kazumi` and only failed
   because the tag didn't exist there.

Never interpolate `${{ github.* }}` into a `run:` block — read `$GITHUB_REF` /
`$env:GITHUB_REF` instead. Keep job `permissions` minimal (`contents: read` for
builds, `contents: write` only for the release job).

## Known issues / parked

- **Danmaku is non-functional in fork builds.** `gh secret list` is empty, so
  `DANDANAPI_*` and `KAZUMI_*` compile to empty strings via
  `String.fromEnvironment` — the build succeeds silently and the feature just
  doesn't work. A candidate DanDanPlay AppId was tested against the live API on
  2026-08-03 and rejected with `X-Error-Message: Invalid AppId`; the request never
  reached signature verification, so the paired secret remains unvalidated.
  **Parked** pending a working AppId. The signing scheme itself is correct:
  `base64(sha256(appId + timestamp + path + secret))`, verified independently.
  Empty `KAZUMI_*` used to also break Bangumi search and the three comment
  surfaces, since those requests get signed for the `api.kazumi.fyi` mirror
  and empty credentials draw a 401. Unsigned builds now bypass the mirror
  entirely (guard in `resolveBangumiMirrorPath` / `shouldSignProtectedMirrorRequest`
  in `lib/request/core/dio_factory.dart` / `lib/request/clients/bangumi_client.dart`,
  pinned by `test/bangumi_mirror_guard_test.dart`).
- Gate B of the source probe validates the *playlist*, not the *media*, so a
  mid-episode stall is not caught. See the design doc's "Honest limits".
- `pickBestMatch` breaks ties by list order; Levenshtein cannot separate season
  variants differing by one character (observed: three candidates tied at 0.556).
