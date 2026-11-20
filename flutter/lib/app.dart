import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:provider/provider.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/widgets/app_status_badge.dart';
import 'features/auth/auth_controller.dart';
import 'features/knowledge_graph/graph_controller.dart';
import 'features/splash/branded_splash.dart';

class AdaptiveMasteryApp extends StatefulWidget {
  const AdaptiveMasteryApp({
    super.key,
    required this.auth,
    required this.graph,
    this.initialThemeMode,
    this.splashHold = const Duration(milliseconds: 650),
    this.showBrandedSplash = true,
  });

  final AuthController auth;
  final GraphController graph;
  final ThemeMode? initialThemeMode;
  final Duration splashHold;
  final bool showBrandedSplash;

  @override
  State<AdaptiveMasteryApp> createState() => _AdaptiveMasteryAppState();
}

class _AdaptiveMasteryAppState extends State<AdaptiveMasteryApp> {
  late final router = buildRouter(widget.auth);
  late final themes = ThemeController(initialMode: widget.initialThemeMode);
  var _ready = false;
  var _nativeRemoved = false;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_syncTheme);
    if (!widget.showBrandedSplash) {
      _ready = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _removeNativeSplash());
      _syncTheme();
    } else {
      _boot();
    }
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

  void _removeNativeSplash() {
    if (_nativeRemoved) return;
    _nativeRemoved = true;
    FlutterNativeSplash.remove();
    // iOS often keeps the launch screen until the next frame / touch without this.
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> _boot() async {
    // Theme first so the Flutter splash matches dark/light preference.
    if (widget.initialThemeMode == null) {
      await themes.restoreLastMode();
    }
    if (!mounted) return;
    // Drop the (often system-light) native splash as soon as our themed splash paints.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _removeNativeSplash();
    });

    await Future.wait([
      widget.auth.loadMe(),
      Future<void>.delayed(widget.splashHold),
    ]);
    if (!mounted) return;
    await themes.bindUser(widget.auth.user?.id);
    if (!mounted) return;

    // Load the graph under the splash so the first visible frame is centered.
    // Otherwise InteractiveViewer paints one identity-transform frame (left strip
    // of a wide canvas — looks like a drawer covering the right).
    if (widget.auth.user != null) {
      await widget.graph.resume();
      if (!mounted) return;
      // Router may still be mounting GraphScreen; give it frames to layout + snap.
      for (var i = 0; i < 4; i++) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
    }

    setState(() => _ready = true);
    // Force a paint so the overlay actually tears down without waiting for a gesture.
    SchedulerBinding.instance.scheduleFrame();
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
          final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
          final splashDark = ThemeController.isDark(themes.mode, platform);
          return MaterialApp.router(
            title: 'learnfromai',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            darkTheme: buildTheme(brightness: Brightness.dark),
            themeMode: themes.mode,
            routerConfig: router,
            builder: (context, child) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Match scaffold paper under the router so no black window shows through.
                  ColoredBox(
                    color: splashDark ? BrandedSplash.paperDark : BrandedSplash.paperLight,
                  ),
                  if (child != null) child,
                  // Above every route / drawer / sheet so limit notices stay readable.
                  if (_ready) const AppStatusBadgeHost(),
                  if (!_ready)
                    Positioned.fill(
                      child: AbsorbPointer(
                        child: BrandedSplash(dark: splashDark),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
