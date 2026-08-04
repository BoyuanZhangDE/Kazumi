import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  group('needUpdate', () {
    test('this fork\'s namespaced tag with a newer patch is an update', () {
      expect(needUpdate('2.2.6', 'autosource/v2.2.6.2'), isTrue);
    });

    test('a plain v-prefixed tag equal to the local version is not an update',
        () {
      expect(needUpdate('2.2.6', 'v2.2.6'), isFalse);
    });

    test('a non-numeric tag is not an update and does not throw', () {
      expect(() => needUpdate('2.2.6', 'not-a-version'), returnsNormally);
      expect(needUpdate('2.2.6', 'not-a-version'), isFalse);
    });
  });
}
