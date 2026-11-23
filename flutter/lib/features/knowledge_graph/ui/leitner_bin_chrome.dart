import 'package:flutter/material.dart';

/// Visual grouping and colors for Leitner chart bins (Talivo-style).
class LeitnerBinChrome {
  LeitnerBinChrome._();

  static const learningBlue = Color(0xFFB7D9EA);
  static const familiarBlue = Color(0xFF6BA8C4);
  static const strongBlue = Color(0xFF3A7A9C);
  static const masteredGold = Color.fromARGB(255, 223, 175, 17);
  static const dueOrange = Color.fromARGB(255, 255, 199, 94);
  static const maxVisualCardsPerBin = 150;
  static const minVisualScaleCards = 50;
  static const tuckStripes = 2;
  static const onFill = Colors.white;

  static int visualCardCount(int count) {
    if (count <= 0) return 0;
    return count > maxVisualCardsPerBin ? maxVisualCardsPerBin : count;
  }

  static int stackStripeCount(int count) {
    final visual = visualCardCount(count);
    if (visual == 0) return 0;
    return visual + tuckStripes;
  }

  static LeitnerBinGroup groupForBin(int bin, {required int graduationBin}) {
    // 1–2 learning, 3–4 familiar, 5–6 strong, graduationBin+ (7+) mastered.
    if (bin >= graduationBin) return LeitnerBinGroup.mastered;
    if (bin <= 2) return LeitnerBinGroup.learning;
    if (bin <= 4) return LeitnerBinGroup.familiar;
    return LeitnerBinGroup.strong;
  }

  static Color fillForBin(int bin, {required int graduationBin}) {
    switch (groupForBin(bin, graduationBin: graduationBin)) {
      case LeitnerBinGroup.learning:
        return learningBlue;
      case LeitnerBinGroup.familiar:
        return familiarBlue;
      case LeitnerBinGroup.strong:
        return strongBlue;
      case LeitnerBinGroup.mastered:
        return masteredGold;
    }
  }

  static Color fillForGroup(LeitnerBinGroup group) {
    switch (group) {
      case LeitnerBinGroup.learning:
        return learningBlue;
      case LeitnerBinGroup.familiar:
        return familiarBlue;
      case LeitnerBinGroup.strong:
        return strongBlue;
      case LeitnerBinGroup.mastered:
        return masteredGold;
    }
  }

  static Color axisBadgeRing(ColorScheme scheme) {
    return scheme.brightness == Brightness.dark
        ? scheme.surfaceContainerHighest
        : Colors.white.withValues(alpha: 0.94);
  }

  static String groupLabel(LeitnerBinGroup group) {
    switch (group) {
      case LeitnerBinGroup.learning:
        return 'Learning';
      case LeitnerBinGroup.familiar:
        return 'Familiar';
      case LeitnerBinGroup.strong:
        return 'Strong';
      case LeitnerBinGroup.mastered:
        return 'Mastered';
    }
  }
}

enum LeitnerBinGroup { learning, familiar, strong, mastered }
