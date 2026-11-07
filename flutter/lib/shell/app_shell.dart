import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/widgets/app_bottom_nav.dart';
import '../core/widgets/gradient_top_bar.dart';
import '../features/knowledge_graph/graph_controller.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final next = switch (path) {
      '/graph' => 0,
      '/trajectory' || '/learn' => 1,
      '/review' => 2,
      '/mastery' => 3,
      _ => null,
    };
    if (next != null) _index = next;
    final settings = path == '/settings';
    final nested = settings || path == '/learn';
    final title = switch (path) {
      '/trajectory' => 'Trajectories',
      '/learn' => 'Learn',
      '/review' => 'Review',
      '/mastery' => 'Mastery',
      '/settings' => 'Settings',
      _ => 'Graph',
    };
    return Scaffold(
      appBar: GradientTopBar(
        title: title,
        leading: nested
            ? IconButton(
                tooltip: 'Back',
                onPressed: () => context.go(path == '/learn' ? '/trajectory' : '/graph'),
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        actions: settings
            ? null
            : [
                IconButton(tooltip: 'Settings', onPressed: () => context.go('/settings'), icon: const Icon(Icons.settings_outlined)),
              ],
      ),
      body: widget.child,
      bottomNavigationBar: AppBottomNav(
        currentIndex: _index,
        onTap: (value) {
          if (value == 0) context.read<GraphController>().focusTrajectory(null);
          context.go(switch (value) {
            1 => '/trajectory',
            2 => '/review',
            3 => '/mastery',
            _ => '/graph',
          });
        },
      ),
    );
  }
}
