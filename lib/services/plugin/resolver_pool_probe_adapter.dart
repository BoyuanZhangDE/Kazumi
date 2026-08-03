import 'package:kazumi/services/plugin/source_probe.dart';
import 'package:kazumi/services/video_source/video_source_resolver_pool.dart';

/// Thin [ProbeResolveFn] adapter over [VideoSourceResolverPool]. Owns lease
/// lifecycle only: acquires a lease per candidate and always releases it
/// back to the pool once the resolve settles, win or lose.
///
/// [SourceProbe] itself cannot cancel an in-flight resolve (its
/// [ProbeResolveFn] signature carries no cancellation token) — call
/// [cancelAll] once a race has settled (winner found, or
/// [SourceProbe.cancel] was called) so abandoned losers stop holding a
/// WebView worker.
class ResolverPoolProbeAdapter {
  ResolverPoolProbeAdapter(this._pool);

  final VideoSourceResolverPool _pool;
  final Map<String, VideoSourceResolverLease> _activeLeases = {};

  Future<String> resolve(ProbeCandidate candidate) async {
    final key = _keyFor(candidate);
    final lease = _pool.tryAcquire(key);
    if (lease == null) {
      throw StateError('No resolver worker available for $key');
    }

    _activeLeases[key] = lease;
    try {
      final source = await lease.resolve(
        candidate.episodeUrl,
        useLegacyParser: candidate.useLegacyParser,
      );
      return source.url;
    } finally {
      _activeLeases.remove(key);
      _pool.release(lease);
    }
  }

  /// Cancels every resolve this adapter currently has in flight.
  void cancelAll() {
    for (final lease in _activeLeases.values.toList()) {
      lease.cancel();
    }
  }

  String _keyFor(ProbeCandidate candidate) =>
      '${candidate.pluginName}#${candidate.roadIndex}#${candidate.episodeUrl}';
}
