import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/auth/auth_controller.dart';
import 'features/goals/goals_controller.dart';
import 'features/knowledge_graph/graph_controller.dart';
import 'features/learning/learn_controller.dart';
import 'features/mastery/mastery_controller.dart';
import 'features/review/review_controller.dart';

class AdaptiveMasteryApp extends StatefulWidget {
  const AdaptiveMasteryApp({super.key, required this.auth, required this.goals, required this.graph, required this.learn, required this.review, required this.mastery});

  final AuthController auth;
  final GoalsController goals;
  final GraphController graph;
  final LearnController learn;
  final ReviewController review;
  final MasteryController mastery;

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
        ChangeNotifierProvider.value(value: widget.goals),
        ChangeNotifierProvider.value(value: widget.graph),
        ChangeNotifierProvider.value(value: widget.learn),
        ChangeNotifierProvider.value(value: widget.review),
        ChangeNotifierProvider.value(value: widget.mastery),
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
