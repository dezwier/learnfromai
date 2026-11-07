import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({super.key, required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const _items = [
    (icon: Icons.account_tree_outlined, active: Icons.account_tree, label: 'Graph'),
    (icon: Icons.route_outlined, active: Icons.route, label: 'Trajectories'),
    (icon: Icons.replay_outlined, active: Icons.replay, label: 'Review'),
    (icon: Icons.insights_outlined, active: Icons.insights, label: 'Mastery'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.colorScheme.surface;
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final items = [
      for (final item in _items)
        BottomNavigationBarItem(icon: Icon(item.icon), activeIcon: Icon(item.active), label: item.label),
    ];
    final nav = isIos
        ? CupertinoTabBar(
            currentIndex: currentIndex,
            border: const Border(),
            backgroundColor: background,
            activeColor: theme.colorScheme.onSurface,
            inactiveColor: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            onTap: onTap,
            items: items,
          )
        : BottomNavigationBar(
            currentIndex: currentIndex,
            type: BottomNavigationBarType.fixed,
            backgroundColor: background,
            elevation: 0,
            selectedItemColor: theme.colorScheme.onSurface,
            unselectedItemColor: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            onTap: onTap,
            items: items,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.35), width: 0.5)),
      ),
      child: Theme(
        data: theme.copyWith(canvasColor: background, splashColor: Colors.transparent, highlightColor: Colors.transparent),
        child: nav,
      ),
    );
  }
}
