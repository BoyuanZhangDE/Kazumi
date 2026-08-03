import 'dart:convert';

/// A source that has cleared both probe gates for a show, remembered so the
/// next open can try it first. A hint only — never trusted without probing.
class PlayableSourceRecord {
  final String pluginName;
  final String src;
  final int roadIndex;
  final DateTime lastGoodAt;

  const PlayableSourceRecord({
    required this.pluginName,
    required this.src,
    required this.roadIndex,
    required this.lastGoodAt,
  });

  bool isExpired(DateTime now, {Duration ttl = PlayableSourceCache.ttl}) {
    return now.difference(lastGoodAt) > ttl;
  }

  Map<String, dynamic> toJson() => {
        'pluginName': pluginName,
        'src': src,
        'roadIndex': roadIndex,
        'lastGoodAt': lastGoodAt.toIso8601String(),
      };

  factory PlayableSourceRecord.fromJson(Map<String, dynamic> json) {
    return PlayableSourceRecord(
      pluginName: json['pluginName'] as String,
      src: json['src'] as String,
      roadIndex: json['roadIndex'] as int,
      lastGoodAt: DateTime.parse(json['lastGoodAt'] as String),
    );
  }
}

/// Returns the raw JSON blob previously written, or null when absent.
typedef CacheReadFn = String? Function();
typedef CacheWriteFn = Future<void> Function(String json);

/// Per-show playable-source cache, stored as a single JSON map keyed by
/// bangumi id. Storage is injected: production wiring reads/writes a JSON
/// string into the existing `setting` box via GStorage.
class PlayableSourceCache {
  static const Duration ttl = Duration(days: 7);

  PlayableSourceCache({required CacheReadFn read, required CacheWriteFn write})
      : _read = read,
        _write = write;

  final CacheReadFn _read;
  final CacheWriteFn _write;

  /// Null when absent OR expired.
  PlayableSourceRecord? get(int bangumiId, {DateTime? now}) {
    final entry = _readMap()[bangumiId.toString()];
    if (entry == null) return null;

    final record = PlayableSourceRecord.fromJson(entry as Map<String, dynamic>);
    if (record.isExpired(now ?? DateTime.now())) return null;
    return record;
  }

  Future<void> put(int bangumiId, PlayableSourceRecord record) async {
    final map = _readMap();
    map[bangumiId.toString()] = record.toJson();
    await _write(jsonEncode(map));
  }

  Future<void> invalidate(int bangumiId) async {
    final map = _readMap();
    if (map.remove(bangumiId.toString()) != null) {
      await _write(jsonEncode(map));
    }
  }

  Map<String, dynamic> _readMap() {
    final raw = _read();
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }
}
