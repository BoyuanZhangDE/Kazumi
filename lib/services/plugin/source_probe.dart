import 'dart:async';

/// Why a [ProbeCandidate] did or did not end up playable.
enum ProbeOutcome { playable, resolveFailed, validateFailed, cancelled }

/// One source worth racing: a specific plugin/road/episode combination.
class ProbeCandidate {
  final String pluginName;
  final String src; // detail-page url for this show on this source
  final String episodeUrl; // fully-qualified episode page url to resolve
  final int roadIndex;
  final bool useLegacyParser;
  final Map<String, String> httpHeaders; // from plugin.buildHttpHeaders()

  const ProbeCandidate({
    required this.pluginName,
    required this.src,
    required this.episodeUrl,
    required this.roadIndex,
    required this.useLegacyParser,
    required this.httpHeaders,
  });
}

/// Progress snapshot emitted as each candidate clears or fails the race.
class ProbeProgress {
  final int completed;
  final int total;
  final String? currentPluginName;

  const ProbeProgress({
    required this.completed,
    required this.total,
    this.currentPluginName,
  });
}

/// Final verdict for one candidate.
class ProbeResult {
  final ProbeCandidate candidate;
  final ProbeOutcome outcome;
  final String? videoUrl; // non-null iff outcome == playable

  const ProbeResult({
    required this.candidate,
    required this.outcome,
    this.videoUrl,
  });
}

/// Gate A: turn a candidate's episode page into a video url (WebView resolve).
typedef ProbeResolveFn = Future<String> Function(ProbeCandidate candidate);

/// Gate B: confirm a resolved video url actually plays.
typedef ProbeValidateFn = Future<bool> Function(
    String videoUrl, Map<String, String> headers);

/// Races candidates through gate A (resolve) then gate B (validate) and
/// returns the first one to clear both. Both gates are caller-injected so
/// this stays free of WebView/HTTP concerns.
class SourceProbe {
  SourceProbe({
    required ProbeResolveFn resolve,
    required ProbeValidateFn validate,
    this.concurrency = 3,
  })  : _resolve = resolve,
        _validate = validate;

  final ProbeResolveFn _resolve;
  final ProbeValidateFn _validate;
  final int concurrency;

  Completer<ProbeResult?>? _activeCompleter;

  /// Returns the first candidate clearing both gates, cancelling the rest.
  /// Returns null when no candidate passes, or the list is empty.
  Future<ProbeResult?> findFirstPlayable(
    List<ProbeCandidate> candidates, {
    void Function(ProbeProgress)? onProgress,
  }) {
    if (candidates.isEmpty) return Future.value(null);

    final completer = Completer<ProbeResult?>();
    _activeCompleter = completer;

    int nextIndex = 0;
    int completedCount = 0;
    int activeWorkers = 0;

    Future<void> runWorker() async {
      activeWorkers++;
      try {
        while (!completer.isCompleted && nextIndex < candidates.length) {
          final candidate = candidates[nextIndex++];

          ProbeOutcome outcome;
          String? videoUrl;
          try {
            final resolved = await _resolve(candidate);
            // A straggler whose resolve landed after the race was already
            // won or cancelled must not spend an HTTP round trip on gate B.
            if (completer.isCompleted) return;
            try {
              if (await _validate(resolved, candidate.httpHeaders)) {
                outcome = ProbeOutcome.playable;
                videoUrl = resolved;
              } else {
                outcome = ProbeOutcome.validateFailed;
              }
            } catch (_) {
              outcome = ProbeOutcome.validateFailed;
            }
          } catch (_) {
            outcome = ProbeOutcome.resolveFailed;
          }

          // Cancelled or already won while this candidate was in flight.
          if (completer.isCompleted) return;

          completedCount++;
          onProgress?.call(ProbeProgress(
            completed: completedCount,
            total: candidates.length,
            currentPluginName: candidate.pluginName,
          ));

          if (outcome == ProbeOutcome.playable) {
            completer.complete(ProbeResult(
              candidate: candidate,
              outcome: outcome,
              videoUrl: videoUrl,
            ));
            return;
          }
        }
      } finally {
        activeWorkers--;
        if (activeWorkers == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }
    }

    final workerCount = concurrency.clamp(1, candidates.length).toInt();
    for (var i = 0; i < workerCount; i++) {
      unawaited(runWorker());
    }

    return completer.future.whenComplete(() {
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
      }
    });
  }

  /// Makes an in-progress [findFirstPlayable] complete with null promptly.
  /// Candidates already in flight keep running to completion but their
  /// results are discarded; callers are responsible for releasing any
  /// resources (e.g. WebView leases) those abandoned resolves hold.
  void cancel() {
    final completer = _activeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }
}
