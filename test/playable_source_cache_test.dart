import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/playable_source_cache.dart';

void main() {
  group('PlayableSourceCache', () {
    test('put then get round-trips every field', () async {
      String? storedJson;
      final cache = PlayableSourceCache(
        read: () => storedJson,
        write: (json) async => storedJson = json,
      );
      final now = DateTime.utc(2026, 1, 1);

      await cache.put(
        1,
        PlayableSourceRecord(
          pluginName: 'plugin_a',
          src: 'https://example.com/show-a',
          roadIndex: 2,
          lastGoodAt: now,
        ),
      );
      final result = cache.get(1, now: now);

      expect(result, isNotNull);
      expect(result!.pluginName, 'plugin_a');
      expect(result.src, 'https://example.com/show-a');
      expect(result.roadIndex, 2);
      expect(result.lastGoodAt, now);
    });

    test('an entry older than the 7-day ttl reads back as null', () async {
      String? storedJson;
      final cache = PlayableSourceCache(
        read: () => storedJson,
        write: (json) async => storedJson = json,
      );
      final lastGoodAt = DateTime.utc(2026, 1, 1);
      await cache.put(
        1,
        PlayableSourceRecord(
          pluginName: 'plugin_a',
          src: 'src',
          roadIndex: 0,
          lastGoodAt: lastGoodAt,
        ),
      );

      final afterTtl =
          lastGoodAt.add(PlayableSourceCache.ttl).add(const Duration(seconds: 1));
      final result = cache.get(1, now: afterTtl);

      expect(result, isNull);
    });

    test('an entry inside the ttl reads back fine', () async {
      String? storedJson;
      final cache = PlayableSourceCache(
        read: () => storedJson,
        write: (json) async => storedJson = json,
      );
      final lastGoodAt = DateTime.utc(2026, 1, 1);
      await cache.put(
        1,
        PlayableSourceRecord(
          pluginName: 'plugin_a',
          src: 'src',
          roadIndex: 0,
          lastGoodAt: lastGoodAt,
        ),
      );

      final withinTtl = lastGoodAt
          .add(PlayableSourceCache.ttl)
          .subtract(const Duration(seconds: 1));
      final result = cache.get(1, now: withinTtl);

      expect(result, isNotNull);
      expect(result!.pluginName, 'plugin_a');
    });

    test('records are keyed per bangumi id; one show never leaks into another',
        () async {
      String? storedJson;
      final cache = PlayableSourceCache(
        read: () => storedJson,
        write: (json) async => storedJson = json,
      );
      final now = DateTime.utc(2026, 1, 1);

      await cache.put(
        1,
        PlayableSourceRecord(
          pluginName: 'plugin_a',
          src: 'src_a',
          roadIndex: 0,
          lastGoodAt: now,
        ),
      );
      await cache.put(
        2,
        PlayableSourceRecord(
          pluginName: 'plugin_b',
          src: 'src_b',
          roadIndex: 1,
          lastGoodAt: now,
        ),
      );

      final one = cache.get(1, now: now);
      final two = cache.get(2, now: now);

      expect(one, isNotNull);
      expect(two, isNotNull);
      expect(one!.pluginName, 'plugin_a');
      expect(one.src, 'src_a');
      expect(two!.pluginName, 'plugin_b');
      expect(two.src, 'src_b');
    });

    test('invalidate removes only the targeted show', () async {
      String? storedJson;
      final cache = PlayableSourceCache(
        read: () => storedJson,
        write: (json) async => storedJson = json,
      );
      final now = DateTime.utc(2026, 1, 1);

      await cache.put(
        1,
        PlayableSourceRecord(
          pluginName: 'plugin_a',
          src: 'src_a',
          roadIndex: 0,
          lastGoodAt: now,
        ),
      );
      await cache.put(
        2,
        PlayableSourceRecord(
          pluginName: 'plugin_b',
          src: 'src_b',
          roadIndex: 0,
          lastGoodAt: now,
        ),
      );

      await cache.invalidate(1);

      expect(cache.get(1, now: now), isNull);
      expect(cache.get(2, now: now), isNotNull);
    });

    test('get on empty/absent storage returns null', () {
      final cache = PlayableSourceCache(
        read: () => null,
        write: (json) async {},
      );

      expect(cache.get(1), isNull);
    });

    test('malformed stored JSON returns null rather than throwing', () {
      final cache = PlayableSourceCache(
        read: () => '{not valid json',
        write: (json) async {},
      );

      expect(() => cache.get(1), returnsNormally);
      expect(cache.get(1), isNull);
    });
  });

  group('shouldInvalidateForPlaybackFailure', () {
    test('returns true when the record names the failed plugin', () {
      final record = PlayableSourceRecord(
        pluginName: 'plugin_a',
        src: 'src_a',
        roadIndex: 0,
        lastGoodAt: DateTime.utc(2026, 1, 1),
      );

      expect(
        shouldInvalidateForPlaybackFailure(
          record: record,
          failedPluginName: 'plugin_a',
        ),
        isTrue,
      );
    });

    test(
        'a record naming a DIFFERENT plugin must survive (returns false)',
        () {
      final record = PlayableSourceRecord(
        pluginName: 'plugin_a',
        src: 'src_a',
        roadIndex: 0,
        lastGoodAt: DateTime.utc(2026, 1, 1),
      );

      expect(
        shouldInvalidateForPlaybackFailure(
          record: record,
          failedPluginName: 'plugin_b',
        ),
        isFalse,
      );
    });

    test('returns false when the record is null', () {
      expect(
        shouldInvalidateForPlaybackFailure(
          record: null,
          failedPluginName: 'plugin_a',
        ),
        isFalse,
      );
    });
  });
}
