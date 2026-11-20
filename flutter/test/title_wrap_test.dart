import 'package:adaptive_mastery/features/knowledge_graph/layout/title_wrap.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hyphenBreaks prefers paren|ting for parenting', () {
    final breaks = hyphenBreaks('parenting');
    expect(breaks, contains(5)); // paren|ting
    expect(breaks, isNot(contains(7))); // never parenti|ng
  });

  test('wrap inserts a visible hyphen at a syllable break', () {
    const style = TextStyle(fontSize: 28);
    // Wide enough for "paren-" (syllable) but not the full word.
    final wrapped = wrapTitleWithHyphens(
      text: 'parenting',
      style: style,
      maxWidth: 170,
      maxLines: 4,
      textScaler: TextScaler.noScaling,
    );
    expect(wrapped, contains('-'));
    expect(wrapped.split('\n').first, endsWith('-'));
    expect(wrapped.replaceAll('-', '').replaceAll('\n', ''), 'parenting');
    expect(wrapped, isNot(contains('paraneti-')));
    expect(wrapped, startsWith('paren-'));
    expect(wrapped, contains('ting'));
  });

  test('layoutTitle keeps whole words when they fit after shrinking', () {
    final result = layoutTitle(
      text: 'Birds',
      style: const TextStyle(fontSize: 20),
      maxWidth: 120,
      maxHeight: 80,
      maxLines: 2,
      minFontSize: 8,
      maxFontSize: 20,
      textScaler: TextScaler.noScaling,
    );
    expect(result.text, 'Birds');
    expect(result.text.contains('-'), isFalse);
    expect(result.fontSize, greaterThan(8));
  });

  test('hyphenBreaks finds develop|mental and development|al', () {
    final breaks = hyphenBreaks('Developmental');
    expect(breaks, contains(7)); // Develop|mental
    expect(breaks, contains(11)); // Development|al
    expect(breaks, isNot(contains(12))); // never Developmenta|l
  });

  test('layoutTitle hyphenates long words instead of soft-wrapping a letter', () {
    final result = layoutTitle(
      text: 'Developmental Psychology',
      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
      maxWidth: 96,
      maxHeight: 120,
      maxLines: 4,
      minFontSize: 11,
      maxFontSize: 28,
      textScaler: TextScaler.noScaling,
    );
    expect(result.text.replaceAll('-', '').replaceAll('\n', ' '),
        isNot(contains('Developmenta')));
    if (result.text.contains('-')) {
      expect(result.text.split('\n').where((l) => l.endsWith('-')), isNotEmpty);
      // Never leave a single letter after a hyphen break.
      for (final line in result.text.split('\n')) {
        if (line.endsWith('-')) {
          expect(line.length, greaterThan(2));
        }
      }
    }
  });
}
