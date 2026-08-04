# Automatic Playable-Source Selection

## Problem Statement

**How might we get the user from 开始观看 into a playing video without ever making
them adjudicate a source list — while keeping their escape hatch when we pick the
wrong show?**

Today the user must pick a 播放源 from a bottom sheet before anything plays. The
colored dot next to each source name reflects `PluginSearchStatus` only — i.e.
"the search returned rows" — so a green dot says nothing about whether the video
will actually play. Users don't care about sources; they care about watching.

## Codebase Grounding

Playing a video is a three-stage chain, not one call:

| Stage | Call | Cost | What it proves |
|---|---|---|---|
| 1. Search | `plugin.queryBangumi(keyword)` | HTTP, already parallel across all plugins (`plugin_search_service.dart:69`) | Source has something named like this |
| 2. Chapters | `plugin.queryChapterRoads(src)` | HTTP + parse | Episode list and 播放线路 exist |
| 3. Resolve | `WebViewVideoSourceService.resolve(url)` | Headless WebView page load, 15–30s timeout | It actually plays |

The colored dot is stage 1. The `视频解析超时` error (`video_controller.dart:664`)
is stage 3.

Assets that already exist and should be reused:

- `lib/services/video_source/video_source_resolver_pool.dart` — a working parallel
  resolve pool with lease/cancel/retire semantics, clamped to 5 concurrent
  WebViews. Currently used by exactly one caller (`download_controller.dart:33`).
- `lib/utils/m3u8_parser.dart` — `M3u8Parser.detectType` / `parseMasterPlaylist` /
  `parseMediaPlaylist`, already used by `download_manager.dart:444` and already
  unit-tested in `test/m3u8_parser_test.dart`.
- `lib/services/plugin/plugin_validity_tracker.dart` — 16-line in-memory,
  per-launch, search-only `Set<String>`. The seam for persistence, but it is
  global rather than per-show.

### Why HTTP cannot replace the WebView

The resolver injects JS that monkey-patches `window.Response.prototype.text` and
`XMLHttpRequest.prototype.open` to capture the m3u8 as the page's own script
fetches it (`video_webview_impl.dart:158-175`), plus intercepts `.m3u8` and
`Range:` network requests and scans DOM `<video>` elements on a timer.

The video URL does not exist in any static HTML — it is manufactured at runtime by
the site's obfuscated player JS. That is why 1508 lines of platform WebView
implementations exist. An HTTP-only replacement would be per-site reverse
engineering that breaks on every player update.

HTTP is useful **after** resolution, not instead of it.

## Recommended Direction

Rank cheaply in the background; spend WebViews only at play time, hedged and
validated.

```
Info page opens          →  stage 1 search (already parallel) + stage 2
  (user reads synopsis)     queryChapterRoads on candidates — pure HTTP, no
                            WebView. Yields a ranked candidate list. Free latency.

User taps 开始观看        →  enter the player IMMEDIATELY (episode grid live,
                            片源 dropdown populated). Race gates A+B on top 3.

If still resolving @3s   →  "正在为你选择可用片源" panel in the video area, with
                            determinate progress (n/m sources checked) and
                            per-source status chips reusing the existing
                            colored-dot vocabulary.

Winner                   →  play; persist {source, matched src, roadIndex, ts}
                            per show, TTL 7 days. Losers cancelled.

Next open                →  cached source tried FIRST but still raced against one
                            backup — a stale cache costs ~0, not a 30s timeout.
```

### The two-gate winner definition

A naive race picks "first WebView to emit a URL." That does not guarantee
playback. These failures survive stage 3: m3u8 resolves but the CDN 403s (expired
token or referer check); the captured URL is an ad pre-roll rather than the
episode; the playlist is valid but the segment host is dead, so the player buffers
forever.

| Gate | Mechanism | Cost | Catches |
|---|---|---|---|
| **A — Resolve** | Existing `VideoSourceResolverPool` WebView | 3–15s | Site broken, parser broken, timeout |
| **B — Validate** | Plain HTTP GET the m3u8, assert `200` + `#EXTM3U`; for a master playlist fetch the best variant and require >= 1 segment | ~300ms | Dead CDN, 403, empty or ad-only playlist |

**Winner = first candidate to clear both gates.** Losers get `lease.cancel()`.

Honest limits, as built:

- Gate B validates the *playlist*, not the *media*. It does not fetch segment
  bytes, so a playlist that parses fine while its segment host is dead still
  passes. Adding that check needs a byte-range capability that
  `HttpProbeGetFn` (whose response body is a `String`) cannot express — a
  binary-safe HEAD/Range function would have to be added deliberately.
- Nothing short of playing catches a mid-episode stall.

### Why the cache is a hint, not a promise

The persisted record orders the race; it never short-circuits it. A stale entry
therefore costs nothing — the user never sits through a timeout waiting to
discover the cached source died. This is the property that makes persistence safe
for sources that break weekly.

## Key Assumptions to Validate

- [x] ~~Three concurrent headless WebViews are acceptable on mid-range mobile~~ —
      **retired: this fork is desktop-only.** Mobile memory pressure was the main
      argument for keeping the race narrow, so concurrency 3 stands unchallenged
      on desktop and could be raised if measurement ever justifies it. No mobile
      testing is in scope.
- [ ] Gate B meaningfully catches failures gate A misses — instrument how often
      a resolve succeeds but validation rejects. If it never fires, gate B is dead
      weight; if it fires often, it was the whole point.
- [ ] Stage 2 (`queryChapterRoads`) is cheap enough to run speculatively on info
      page open without tripping source-side rate limits.
- [ ] Auto-picking a search result yields the right show often enough. Measure how
      often users reach for 手动选择 after landing in the player.

## MVP Scope

**In:**

- `SourceProbe` — hedged race over candidates, injectable resolve and validate
  functions, cancel-losers, progress callback.
- `M3u8Validator` — gate B, injectable HTTP getter, reuses `M3u8Parser`.
- `PlayableSourceCache` — per-show record with 7-day TTL, injectable storage.
- `rankCandidates` — cached source first, then search-valid plugins, then rest.
- Player entry without the source sheet; 片源 dropdown left of 播放线路; matched
  title visible in the header; 手动选择 reopens today's sheet with 别名检索 and
  手动检索 intact.
- Progress panel in the video area after a 3s threshold.

**Out:**

- Widget or integration tests for the new UI (no existing infra; keep the UI thin).
- Any change to the rule engine, plugin schema, or the WebView implementations.
- Removing the existing source sheet — it stays, reachable via 手动选择.

## Not Doing (and Why)

- **HTTP-only playability probing** — the video URL is generated by in-page
  obfuscated JS; there is nothing static to scrape. Per-site reverse engineering
  would break continuously.
- **Speculative stage-3 poking on info page open** — three headless WebViews
  loading ad-heavy pages for a show the user may never play is memory-hostile on
  mobile and rude to the source sites. Racing spends the same seconds while the
  user is already waiting.
- **Persisting a verdict that short-circuits the race** — a cache with authority
  costs a full 30s timeout when it goes stale, and these scrapers break weekly.
  Ordering hint only.
- **Auto-picking with no correction affordance** — sources routinely return S1 for
  an S3 query, dubbed cuts, or unrelated shows. Losing 别名检索 and 手动检索 would
  strand the user in the wrong anime.
- **Global-only success-rate ranking** — cheap, but the durable per-show fact is
  the matched `src`, which also skips stages 1–2 on re-open.

## Resolved Questions

- **Which episode does the probe target on resume?** The one the user is actually
  about to watch, not episode 1 — so a verdict is always earned on the real
  target. The cache stays **per show**, not per episode: a per-episode cache is
  coldest exactly where it is needed most (a newly aired episode has no prior
  verdict by definition), and it would not fit the single-JSON-blob storage,
  which is re-decoded on every `get()`.
- **Should a gate-B failure blacklist the source?** No. Successes are scoped to
  the show; failures are not persisted at all. Persisting negatives adds
  staleness surface for no behavioural gain, since the race re-orders anyway.
- **Toolchain.** `flutter` is at `~/develop/flutter/bin`, not on PATH. See
  `CLAUDE.md`.

## Still Open

- Mid-playback stalls are uncovered (gate B validates the playlist, not the
  media). Cheapest mitigation is a 换个片源 action on the player's stall state,
  since the probe machinery is already there.
- `pickBestMatch` ties break by list order; live run showed three DM84 candidates
  tied at 0.556. Acceptable while 手动选择 stays prominent.
- The 3s panel threshold and concurrency 3 are untuned guesses that measured fine
  on desktop. Mobile validation is explicitly out of scope for this fork.
- **Parked:** danmaku is non-functional in fork builds — no `DANDANAPI_*` secrets
  are configured, and a candidate AppId was rejected live with `Invalid AppId`
  (2026-08-03). Unrelated to this feature; see `CLAUDE.md`.

## Status: shipped

Released as [`autosource/v2.2.6.2`](https://github.com/BoyuanZhangDE/Kazumi/releases/tag/autosource/v2.2.6.2)
(macOS `.dmg` + Windows `.zip`, unsigned, desktop-only fork).

All six of the original requirements are met and verified:

| # | Requirement | Evidence |
|---|---|---|
| 1 | 开始观看 straight to player; 片源 left of 播放线路 | I1 passes; dropdown renders before 播放线路 in `video_page.dart` |
| 2 | Default to a source that does not time out | Playback started in 3518ms on `fcdm` |
| 3 | Fast, parallel, well-timed | Concurrency 3; `completed order: [fcdm]` — losers abandoned |
| 4 | Persist per show, reuse next open | A1: cached source ranked first; A3: record updated to the actual winner |
| 5 | Re-poke on timeout, update the list | `视频解析超时，请重试` no longer reachable; B3 proves recovery on resume |
| 6 | Stop at the first working source | `completed order: [fcdm]` |



Design constraint held throughout: every unit takes its I/O as an injected
dependency and never reaches for a WebView or Hive directly.

**Core** (`lib/services/plugin/`): `source_probe.dart`, `m3u8_validator.dart`,
`playable_source_cache.dart`, `candidate_ranker.dart`, `probe_planning.dart`,
`search_result_picker.dart`, plus thin adapters `resolver_pool_probe_adapter.dart`
and `http_probe_client.dart`.

**Wiring**: `video_controller.dart` (probe integration, `pool.resize`, cache),
`video_page.dart` (片源 dropdown, progress panel, failure state),
`info_page.dart` (FAB straight to player), `history_playback_service.dart`
(resume falls back across sources), `video_playback_args.dart`
(`AutoVideoPlaybackArgs`), `settings_keys.dart` (cache key).

### Two decisions taken during implementation

**The info-page search snapshot is an optimisation, not a promise.** The FAB
passes whatever `pluginSearchResponseList` has gathered so far. A user who taps
promptly hands the player an empty list, so `beginAutoSourceSelection` runs its
own full-plugin search rather than reporting "no sources". A *partial* snapshot
races as-is, keeping the fast path fast.

**Candidate selection uses `pickBestMatch`, not the first search result.**
Scrapers routinely return season 1 for a season 3 query, dubbed cuts, or
unrelated shows, and nobody eyeballs the list any more. Items score on
`calculateSimilarity` against the title and every alias. There is deliberately no
minimum threshold — a weak guess the user can correct via 手动选择 beats no
candidate at all. Margins are thin on season discrimination (~0.583 vs ~0.667 on
the season-confusion fixture), so this is a better guess, not a guarantee.

## Test Plan

Offline suite: 163 baseline → **183 passing**, 20 new cases across six files,
following the patterns in `test/async_single_flight_test.dart` and
`test/async_session_test.dart`:

1. `test/source_probe_test.dart` (9) — first-pass-wins, gate B rejects a gate-A
   pass, all-candidates-fail, losers cancelled, concurrency cap respected.
2. `test/playable_source_cache_test.dart` (7) — TTL expiry, per-show keying,
   matched `src` round-trip, stale eviction.
3. `test/m3u8_validation_test.dart` (8) — 200 + `#EXTM3U` passes; 403, empty
   playlist, and non-m3u8 body all fail; master playlist resolves a variant.
4. `test/candidate_ranking_test.dart` (7) — stage-2 results plus cache hint
   produce the expected probe order.
5. `test/probe_planning_test.dart` (15) — remembered-position clamping, and the
   offset-drop-on-source-swap rule.
6. `test/search_result_picker_test.dart` (7) — alias matching, tie stability,
   the no-threshold rule, and a season-confusion case.

### Defects caught by cross-review, not by tests

Recorded because each was invisible to the agent that wrote the code:

- **Straggler double-validate** — `SourceProbe` called gate B on a candidate
  whose gate A landed after the race was already won, burning an HTTP round trip
  and holding a WebView lease. Its own test passed either way, because the test
  held the loser's resolve open forever and never opened the window.
- **Cold-search regression** — the empty-snapshot case reported "no sources" for
  shows with plenty. An interaction between two separately-correct changes.
- **Progress-panel flicker** — a phase boundary reset visibility rather than just
  stopping the countdown, so the panel blinked off and back on mid-wait. Only
  visible reading the assembled flow across two rounds of work.

## Live Verification

Offline tests prove the logic; they cannot prove a source is reachable, that a
rule still parses a live page, or that gate B rejects what gate A passes in the
wild. Live cases are tagged `live` and excluded from the default suite so they
never make CI flaky or hammer third-party sites:

```bash
export PATH="$HOME/develop/flutter/bin:$PATH"
flutter test --tags live --run-skipped     # opt in to the live cases
flutter test                               # 183 pass, live suite skipped, no network
```

`--run-skipped` is required, not optional. A config-file `exclude_tags` unions
with the CLI's exclude set and can never be undone by `--tags`, which would make
the suite permanently unreachable; the tag is therefore marked `skip:` in
`dart_test.yaml` and `--run-skipped` is the supported escape hatch.

The live suite boots an isolated Hive/GStorage instance in a temp dir (the real
`RuleEngine` reads proxy settings through `GStorage`) and never touches real app
storage.

Tier 1 — runnable headlessly, no WebView (stages 1–2 and gate B):

| # | Case | Proves |
|---|---|---|
| L1 | Reach every bundled source's base URL | Which sources are actually up — the premise of the whole feature |
| L2 | Real search across all plugins for a known show | Stage 1 works; rules still parse live HTML |
| L3 | `pickBestMatch` over real, messy search titles | Selection picks the right show from real fuzz |
| L4 | Real `queryChapterRoads` on the chosen `src` | Stage 2 works; roads/episodes are non-empty |
| L5 | Gate B against a known-good public HLS playlist | Validator accepts real media |
| L6 | Gate B against 404 / non-playlist / dead host | Validator rejects real failures rather than throwing |
| L7 | Candidate build end to end from live data | Real episode URLs reach `ProbeCandidate` |

Tier 2 — requires a running app with a WebView, verified by hand:

| # | Case | Expected |
|---|---|---|
| M1 | Play a show whose default source is dead | Race swaps, 已切换到 X toast, video plays |
| M2 | Play a just-aired episode not yet uploaded | 该集数暂时没有可用片源 with three actions, not a dead end |
| M3 | Resume a half-watched episode | Resumes at saved position on the remembered source |
| M4 | Resume when the remembered source is gone | Falls back to another source, offset reset to 0 |
| M5 | Race finishing under 3s | Progress panel never appears |
| M6 | Race exceeding 3s | Panel appears once and does not flicker |
| M7 | 手动选择 from the 片源 dropdown | Full source sheet with 别名检索/手动检索 |

Tier 2 is now largely automated. `integration_test/auto_source_selection_test.dart`
drives the real macOS app through the Dart VM service (no Accessibility permission
needed — OS-level UI scripting via System Events is blocked and times out):

```bash
flutter test integration_test/auto_source_selection_test.dart -d macos
```

It boots the real `app.main()` with `PathProviderPlatform` pointed at an isolated
temp dir, seeded by read-only copying the user's real `plugins.json` (13 installed
sources), so real history/collection/settings are never written.

First full run: 开始观看 went straight to the player, the panel appeared at
+3254ms without flicker, and auto-selection reached **PLAYBACK STARTED in 4476ms**
on source `fcdm` while `mwcy`/`TvTFun` 403'd and `enlie` failed DNS —
`Probe completed order: [fcdm]`, confirming the other two candidates were
abandoned rather than awaited. A second run won on `sorani` in 5.7s.

Scope note: this is a **desktop-only fork**; macOS is the only verification
target and no mobile testing is planned.

### First live run (2026-08-02)

| Case | Result |
|---|---|
| L1 | 7sefun `200` (1.5s) · DM84 `522` · enlie DNS lookup failure |
| L2 | 7sefun 5 results · DM84 3 results · enlie clean `SearchErrorException` in 20ms, no hang |
| L3 | 7sefun picked the exact title (1.000); **DM84 tied all three candidates at 0.556** |
| L4 | 7sefun → 1 road, 12 episodes |
| L5 | Apple public HLS sample → `true` |
| L6 | 404, non-playlist 200 body, dead host → all `false`, no exceptions |
| L7 | 12 `ProbeCandidate`s built, every `episodeUrl` absolute |

Two findings worth carrying forward:

**Base-URL reachability does not predict whether a source works.** DM84's base URL
returned `522` while its *search endpoint* answered fine with 3 results. Any future
"is this source up?" heuristic must probe the endpoint actually used, not the
homepage — and this is a second, independent reason the coloured dot was never a
playability signal.

**`pickBestMatch` ties are broken by list order, and ties are common.** Querying
`间谍过家家` against DM84, all three candidates (第二季 ×2, 第三季) scored an
identical 0.556, so 第三季 won purely for being first. Levenshtein cannot separate
season variants that differ by one character. In production this bites less than
it looks: a Bangumi subject is per-season, so the target title usually carries its
own season marker and matches exactly (as it did on 7sefun), and `bangumiItem.alias`
is also consulted. But when no exact match exists the choice is effectively
arbitrary — confirming this is a better guess, not a guarantee, and that
手动选择 has to stay reachable.
