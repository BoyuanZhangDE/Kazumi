import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/plugin/search_result_picker.dart';

void main() {
  group('pickBestMatch', () {
    test('empty items returns null', () {
      final result = pickBestMatch(items: const [], targetTitle: '尼古喵喵');

      expect(result, isNull);
    });

    test('a single item is returned even when it matches the target badly '
        '(no minimum-score threshold)', () {
      final onlyItem = _item('完全不相关的美食节目', 'only');

      final result = pickBestMatch(
        items: [onlyItem],
        targetTitle: '尼古喵喵',
      );

      expect(result, same(onlyItem));
    });

    test('an exact title match is chosen over a poor one, regardless of '
        'its position in the list', () {
      final poor = _item('尼古喵喵 中配版', 'poor');
      final exact = _item('尼古喵喵', 'exact');

      final result = pickBestMatch(
        items: [poor, exact],
        targetTitle: '尼古喵喵',
      );

      expect(result, same(exact));
    });

    test('an alias match wins when an item matches an alias far better '
        'than it matches targetTitle', () {
      final unrelated = _item('间谍过家家 第二季', 'unrelated');
      final aliasOnly = _item('Mushoku Tensei S3', 'aliasOnly');

      final result = pickBestMatch(
        items: [unrelated, aliasOnly],
        targetTitle: '无职转生 第三季',
        aliases: const ['Mushoku Tensei S3'],
      );

      expect(result, same(aliasOnly));
    });

    test('ties resolve to the earliest item', () {
      final first = _item('齐木楠雄的灾难', 'first');
      final second = _item('齐木楠雄的灾难', 'second');

      final result = pickBestMatch(
        items: [first, second],
        targetTitle: '齐木楠雄的灾难',
      );

      expect(result, same(first));
    });

    test('blank targetTitle with no aliases does not throw and still '
        'returns an item', () {
      final onlyItem = _item('转生史莱姆', 'only');

      expect(
        () => pickBestMatch(items: [onlyItem], targetTitle: ''),
        returnsNormally,
      );
      final result = pickBestMatch(items: [onlyItem], targetTitle: '');
      expect(result, same(onlyItem));
    });

    test('a same-franchise wrong-season item listed first loses to the '
        'correct-season item listed later', () {
      final wrongSeason = _item('无职转生 第二季 高清版', 'wrongSeason');
      final correctSeason = _item('无职转生 第三季 高清版', 'correctSeason');

      final result = pickBestMatch(
        items: [wrongSeason, correctSeason],
        targetTitle: '无职转生 第三季',
      );

      expect(result, same(correctSeason));
    });
  });
}

SearchItem _item(String name, String src) => SearchItem(name: name, src: src);
