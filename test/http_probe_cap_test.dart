// Pure-Dart tests for the body-cap logic in http_probe_client.dart.
//
// Dio's ResponseType.stream plumbing (a real ResponseBody backed by a real
// HttpClientResponse) is not something this repo has a fake-adapter pattern
// for (checked test/ and lib/request/ -- nothing exists), and standing one
// up just for this would be a heavyweight mock for two small pieces of
// logic. Instead, [readCapped] and [buildProbeHeaders] were factored out as
// pure functions in http_probe_client.dart specifically so the cap and the
// Range-merge rule can be unit-tested directly with synthetic streams/maps,
// with no dio/network involved. httpProbeGet's actual wiring (Dio call,
// stream response type, utf8 decode) is exercised only implicitly by
// callers/live tests, not here.
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/http_probe_client.dart';

void main() {
  group('readCapped', () {
    test('chunks smaller than the cap: stream ends before cap, all bytes kept',
        () async {
      final source = Stream<List<int>>.fromIterable([
        [1, 2, 3],
        [4, 5],
      ]);

      final result = await readCapped(source, 100);

      expect(result, [1, 2, 3, 4, 5]);
    });

    test('a chunk exactly crossing the cap boundary stops at the cap',
        () async {
      // cap=5; chunks are [1,2,3] then [4,5,6,7] -- the second chunk crosses
      // the boundary mid-chunk.
      final source = Stream<List<int>>.fromIterable([
        [1, 2, 3],
        [4, 5, 6, 7],
      ]);

      final result = await readCapped(source, 5);

      expect(result, [1, 2, 3, 4, 5]);
    });

    test('a single oversized chunk is truncated to the cap', () async {
      final source = Stream<List<int>>.fromIterable([
        List<int>.generate(1000, (i) => i % 256),
      ]);

      final result = await readCapped(source, 10);

      expect(result, List<int>.generate(10, (i) => i));
    });

    test('an empty stream yields an empty list', () async {
      final source = Stream<List<int>>.fromIterable(const <List<int>>[]);

      final result = await readCapped(source, 100);

      expect(result, isEmpty);
    });

    test(
        'REGRESSION: a body far larger than the cap (the 397MB incident) '
        'stops at the cap instead of being fully consumed', () async {
      const chunkSize = 64 * 1024; // 64KB chunks
      const totalChunks = 6400; // ~400MB total if fully drained
      var chunksProduced = 0;

      Stream<List<int>> hugeBody() async* {
        for (var i = 0; i < totalChunks; i++) {
          chunksProduced++;
          yield List<int>.filled(chunkSize, 0);
        }
      }

      final result = await readCapped(hugeBody(), probeCapBytes);

      expect(result.length, probeCapBytes);
      // The generator must not have been driven anywhere close to
      // completion -- readCapped has to stop consuming once the cap is
      // reached, not just truncate after reading everything.
      expect(chunksProduced, lessThan(totalChunks));
      expect(chunksProduced, lessThanOrEqualTo(2));
    });
  });

  group('buildProbeHeaders', () {
    test('adds a Range header covering exactly the cap when caller sets none',
        () {
      final result = buildProbeHeaders(const {'user-agent': 'test-ua'});

      expect(result['user-agent'], 'test-ua');
      expect(result['Range'], 'bytes=0-${probeCapBytes - 1}');
    });

    test('does not clobber a caller-supplied Range header', () {
      final result = buildProbeHeaders(const {'Range': 'bytes=100-200'});

      expect(result['Range'], 'bytes=100-200');
    });

    test('recognizes a caller Range header regardless of case', () {
      final result = buildProbeHeaders(const {'range': 'bytes=50-99'});

      expect(result['range'], 'bytes=50-99');
      expect(result.containsKey('Range'), isFalse);
    });

    test('empty caller headers still get a Range header', () {
      final result = buildProbeHeaders(const {});

      expect(result['Range'], 'bytes=0-${probeCapBytes - 1}');
    });
  });
}
