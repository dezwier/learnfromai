import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/auth/auth_controller.dart';
import 'features/knowledge_graph/graph_controller.dart';

class AdaptiveMasteryApp extends StatefulWidget {
  const AdaptiveMasteryApp({super.key, required this.auth, required this.graph});

  final AuthController auth;
  final GraphController graph;

  @override
  State<AdaptiveMasteryApp> createState() => _AdaptiveMasteryAppState();
}

class _AdaptiveMasteryAppState extends State<AdaptiveMasteryApp> {
  late final router = buildRouter(widget.auth);
  final themes = ThemeController();

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_syncTheme);
    _syncTheme();
  }

  @override
  void dispose() {
    widget.auth.removeListener(_syncTheme);
    themes.dispose();
    super.dispose();
  }

  void _syncTheme() {
    themes.bindUser(widget.auth.user?.id);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.auth),
        ChangeNotifierProvider.value(value: themes),
        ChangeNotifierProvider.value(value: widget.graph),
      ],
      child: ListenableBuilder(
        listenable: themes,
        builder: (context, _) {
          return MaterialApp.router(
            title: 'Adaptive Mastery',
            theme: buildTheme(),
            darkTheme: buildTheme(brightness: Brightness.dark),
            themeMode: themes.mode,
            routerConfig: router,
          );
        },
      ),
    );
  }
}
