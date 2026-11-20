import 'package:flutter/painting.dart';

/// Layout width fudge: Text paint is often slightly wider than TextPainter.
const _wrapWidthFactor = 0.84;

/// Layout label text: shrink to keep whole words; when a word must break,
/// wrap at syllable boundaries with a visible hyphen (newspaper-style).
///
/// The returned [text] already contains `\n` (and `-` where needed). Display it
/// with `softWrap: false` so Flutter cannot re-break mid-word without a hyphen.
({String text, double fontSize}) layoutTitle({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
  required int maxLines,
  required double minFontSize,
  required double maxFontSize,
  required TextScaler textScaler,
  bool hyphenateAtMinSize = true,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || maxWidth <= 1) {
    return (text: trimmed, fontSize: minFontSize);
  }

  final wrapWidth = maxWidth * _wrapWidthFactor;

  var lo = minFontSize;
  var hi = maxFontSize;
  var best = minFontSize;
  var found = false;
  for (var i = 0; i < 16; i++) {
    final mid = (lo + hi) / 2;
    if (_fitsWholeWords(
      text: trimmed,
      style: style.copyWith(fontSize: mid),
      maxWidth: wrapWidth,
      maxHeight: maxHeight,
      maxLines: maxLines,
      textScaler: textScaler,
    )) {
      found = true;
      best = mid;
      lo = mid;
    } else {
      hi = mid;
    }
  }

  final fontSize = found ? best : minFontSize;
  if (!found && !hyphenateAtMinSize) {
    return (text: trimmed, fontSize: fontSize);
  }

  // Always pre-wrap at the chosen size. Callers must use softWrap: false.
  final wrapped = wrapTitleWithHyphens(
    text: trimmed,
    style: style.copyWith(fontSize: fontSize),
    maxWidth: wrapWidth,
    maxLines: maxLines,
    textScaler: textScaler,
  );
  return (text: wrapped, fontSize: fontSize);
}

bool _fitsWholeWords({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
  required int maxLines,
  required TextScaler textScaler,
}) {
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    if (_measure(word, style, textScaler) > maxWidth) return false;
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    textScaler: textScaler,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  if (painter.didExceedMaxLines) return false;
  if (painter.height > maxHeight + 0.5) return false;
  for (final metric in painter.computeLineMetrics()) {
    if (metric.width > maxWidth + 0.5) return false;
  }
  return true;
}

double _measure(String text, TextStyle style, TextScaler textScaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  return painter.width;
}

/// Insert hard '-' + newlines so mid-word wraps always show a hyphen.
String wrapTitleWithHyphens({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required int maxLines,
  required TextScaler textScaler,
}) {
  final words = [
    for (final word in text.split(RegExp(r'\s+')))
      if (word.isNotEmpty) word,
  ];
  if (words.isEmpty) return text;

  final lines = <String>[];
  var current = '';

  double widthOf(String value) => _measure(value, style, textScaler);

  void pushCurrent() {
    if (current.isEmpty) return;
    lines.add(current);
    current = '';
  }

  for (final word in words) {
    if (lines.length >= maxLines) break;
    final candidate = current.isEmpty ? word : '$current $word';
    if (widthOf(candidate) <= maxWidth) {
      current = candidate;
      continue;
    }

    // Start a new line for this word.
    pushCurrent();
    if (lines.length >= maxLines) break;

    if (widthOf(word) <= maxWidth) {
      current = word;
      continue;
    }

    // Word alone is too wide — hyphenate across remaining lines.
    var rest = word;
    while (rest.isNotEmpty && lines.length < maxLines) {
      if (widthOf(rest) <= maxWidth) {
        current = rest;
        rest = '';
        break;
      }
      final lastLine = lines.length >= maxLines - 1 && current.isEmpty;
      var breakAt = _bestBreak(
        word: rest,
        style: style,
        maxWidth: maxWidth,
        textScaler: textScaler,
      );
      if (breakAt == null) {
        breakAt = _forcedBreak(rest, style, maxWidth, textScaler);
      }
      if (breakAt == null || lastLine) {
        current = rest;
        rest = '';
        break;
      }
      lines.add('${rest.substring(0, breakAt)}-');
      rest = rest.substring(breakAt);
      current = '';
    }
    if (rest.isNotEmpty && lines.length < maxLines) {
      current = rest;
    }
  }
  pushCurrent();
  if (lines.isEmpty) return text;
  return lines.take(maxLines).join('\n');
}

/// Break indices: split BEFORE this character index (so left = substring(0, i)).
/// Never leaves a single letter alone on either side.
List<int> hyphenBreaks(String word) {
  if (word.length < 4) return const [];
  final lower = word.toLowerCase();
  final breaks = <int>{};

  bool isVowel(String ch) => 'aeiouy'.contains(ch.toLowerCase());
  // Default: ≥2 on the left, ≥3 on the right (avoids parenti|ng).
  bool allowed(int i, {int minRight = 3}) =>
      i >= 2 && word.length - i >= minRight;

  // Classic VC|CV syllable boundary → parenting → paren|ting,
  // developmental → develop|mental.
  for (var i = 2; i + 1 < word.length; i++) {
    final a = word[i - 2];
    final b = word[i - 1];
    final c = word[i];
    final d = word[i + 1];
    if (allowed(i) && isVowel(a) && !isVowel(b) && !isVowel(c) && isVowel(d)) {
      breaks.add(i);
    }
  }

  // After a vowel before a consonant.
  for (var i = 2; i < word.length; i++) {
    if (!allowed(i)) continue;
    if (!isVowel(word[i - 1]) || isVowel(word[i])) continue;
    breaks.add(i);
  }

  // Common English suffixes (short ones like "al" may leave 2 letters on the right).
  const suffixes = [
    'tion',
    'sion',
    'ment',
    'ness',
    'ting',
    'ing',
    'ous',
    'ity',
    'ies',
    'ers',
    'est',
    'ive',
    'ial',
    'ful',
    'less',
    'able',
    'ible',
    'ical',
    'ology',
    'al',
    'ic',
    'ly',
    'ed',
    'er',
  ];
  for (final suffix in suffixes) {
    if (!lower.endsWith(suffix)) continue;
    final i = word.length - suffix.length;
    final minRight = suffix.length >= 3 ? 3 : 2;
    if (allowed(i, minRight: minRight)) breaks.add(i);
  }

  final sorted = breaks.toList()..sort();
  return sorted;
}

int? _bestBreak({
  required String word,
  required TextStyle style,
  required double maxWidth,
  required TextScaler textScaler,
}) {
  final opportunities = hyphenBreaks(word);
  // Prefer the longest left part that still fits with a trailing '-'.
  for (final i in opportunities.reversed) {
    final left = '${word.substring(0, i)}-';
    if (_measure(left, style, textScaler) <= maxWidth) return i;
  }
  return null;
}

/// Widest prefix that fits with '-', preferring ≥2 letters on each side.
int? _forcedBreak(
  String word,
  TextStyle style,
  double maxWidth,
  TextScaler textScaler,
) {
  if (word.length < 2) return null;
  for (var i = word.length - 2; i >= 2; i--) {
    if (_measure('${word.substring(0, i)}-', style, textScaler) <= maxWidth) {
      return i;
    }
  }
  for (var i = word.length - 1; i >= 1; i--) {
    if (_measure('${word.substring(0, i)}-', style, textScaler) <= maxWidth) {
      return i;
    }
  }
  return 1;
}
