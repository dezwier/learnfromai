import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';

/// Full-width top fade so HUD text stays readable over the graph (Mesozoic-style).
class ProfileTopFade extends StatelessWidget {
  const ProfileTopFade({super.key});

  static const double fadeExtension = 48;

  static double height(BuildContext context) =>
      MediaQuery.paddingOf(context).top + 72 + fadeExtension;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.88),
              Colors.black.withValues(alpha: 0.58),
              Colors.black.withValues(alpha: 0.25),
              Colors.black.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.32, 0.68, 1.0],
          ),
        ),
      ),
    );
  }
}

/// Top-left profile chip: avatar, level, name, title, XP bar — no card chrome.
class ProfileHud extends StatelessWidget {
  const ProfileHud({super.key, required this.onTap});

  final VoidCallback onTap;

  /// Placeholder progression until learning XP exists.
  static const int placeholderLevel = 1;
  static const int placeholderXp = 0;
  static const int placeholderNextXp = 100;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthController>();
    final profile = auth.user;
    final name = profile?.hudName ?? 'Learner';
    final initial = profile?.initial ?? 'L';
    final photoUrl = profile?.photoUrl;
    final photoBytes = auth.photoBytes;

    const nameColor = Color(0xFFF8F4EC);
    final muted = Colors.white.withValues(alpha: 0.82);
    final xpMuted = Colors.white.withValues(alpha: 0.78);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 8, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AvatarWithLevel(
                initial: initial,
                photoUrl: photoUrl,
                photoBytes: photoBytes,
                level: placeholderLevel,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: nameColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        shadows: [
                          Shadow(
                            color: Color(0xCC000000),
                            blurRadius: 6,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'Learner',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        height: 1.15,
                        shadows: const [
                          Shadow(
                            color: Color(0xAA000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 5),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 72,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.35),
                                width: 0.75,
                              ),
                              color: Colors.black.withValues(alpha: 0.35),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: SizedBox(
                                height: 4,
                                child: LinearProgressIndicator(
                                  value: placeholderNextXp > 0
                                      ? placeholderXp / placeholderNextXp
                                      : 1,
                                  backgroundColor: Colors.transparent,
                                  color: const Color(0xFFC8CDD3),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text.rich(
                          TextSpan(
                            style: TextStyle(
                              color: xpMuted,
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                              shadows: const [
                                Shadow(
                                  color: Color(0xAA000000),
                                  blurRadius: 4,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            children: [
                              TextSpan(text: '$placeholderXp / $placeholderNextXp'),
                              TextSpan(
                                text: ' XP',
                                style: TextStyle(color: scheme.primary.withValues(alpha: 0.95)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvatarWithLevel extends StatelessWidget {
  const _AvatarWithLevel({
    required this.initial,
    required this.level,
    this.photoUrl,
    this.photoBytes,
  });

  final String initial;
  final int level;
  final String? photoUrl;
  final Uint8List? photoBytes;

  static const double _size = 52;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final memory = photoBytes != null && photoBytes!.isNotEmpty;
    final network = !memory &&
        photoUrl != null &&
        photoUrl!.trim().isNotEmpty &&
        (photoUrl!.startsWith('http://') || photoUrl!.startsWith('https://'));
    return SizedBox(
      width: _size + 4,
      height: _size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 2,
            top: 0,
            child: Container(
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFE8EAEE),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: memory
                  ? Image.memory(
                      photoBytes!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _Initial(initial: initial),
                    )
                  : network
                      ? Image.network(
                          photoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _Initial(initial: initial),
                        )
                      : _Initial(initial: initial),
            ),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary,
                border: Border.all(color: const Color(0xFFF8F4EC), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                '$level',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initial,
        style: const TextStyle(
          color: Color(0xFF5C6370),
          fontWeight: FontWeight.w700,
          fontSize: 20,
        ),
      ),
    );
  }
}
