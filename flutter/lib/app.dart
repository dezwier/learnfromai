import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:provider/provider.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/auth/auth_controller.dart';
import 'features/knowledge_graph/graph_controller.dart';
import 'features/splash/branded_splash.dart';

class AdaptiveMasteryApp extends StatefulWidget {
  const AdaptiveMasteryApp({
    super.key,
    required this.auth,
    required this.graph,
    this.splashHold = const Duration(milliseconds: 650),
  });

  final AuthController auth;
  final GraphController graph;
  final Duration splashHold;

  @override
  State<AdaptiveMasteryApp> createState() => _AdaptiveMasteryAppState();
}

class _AdaptiveMasteryAppState extends State<AdaptiveMasteryApp> {
  late final router = buildRouter(widget.auth);
  final themes = ThemeController();
  var _ready = false;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_syncTheme);
    _syncTheme();
    _boot();
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

  Future<void> _boot() async {
    await Future.wait([
      widget.auth.loadMe(),
      Future<void>.delayed(widget.splashHold),
    ]);
    if (!mounted) return;
    FlutterNativeSplash.remove();
    setState(() => _ready = true);
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
          if (!_ready) {
            return MaterialApp(
              title: 'learnfromai',
              debugShowCheckedModeBanner: false,
              theme: buildTheme(),
              darkTheme: buildTheme(brightness: Brightness.dark),
              themeMode: themes.mode,
              home: const BrandedSplash(),
            );
          }
          return MaterialApp.router(
            title: 'learnfromai',
            debugShowCheckedModeBanner: false,
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
