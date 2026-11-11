import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';

/// Top-left profile chip: avatar, level, name, title, XP bar.
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
    final dark = scheme.brightness == Brightness.dark;
    final auth = context.watch<AuthController>();
    final profile = auth.user;
    final name = profile?.hudName ?? 'Learner';
    final initial = profile?.initial ?? 'L';
    final photoUrl = profile?.photoUrl;

    final nameColor = dark ? const Color(0xFFF4F1EA) : const Color(0xFF1C2430);
    final muted = nameColor.withValues(alpha: 0.72);
    final chipFill = dark ? const Color(0xCC1C2430) : const Color(0xE6FFFFFF);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          decoration: BoxDecoration(
            color: chipFill,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AvatarWithLevel(
                initial: initial,
                photoUrl: photoUrl,
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
                      style: TextStyle(
                        color: nameColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
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
                      ),
                    ),
                    const SizedBox(height: 5),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 72,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: placeholderNextXp > 0
                                  ? placeholderXp / placeholderNextXp
                                  : 1,
                              minHeight: 4,
                              backgroundColor: scheme.outline.withValues(alpha: 0.25),
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text.rich(
                          TextSpan(
                            style: TextStyle(
                              color: muted,
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                            ),
                            children: [
                              TextSpan(text: '$placeholderXp / $placeholderNextXp'),
                              TextSpan(
                                text: ' XP',
                                style: TextStyle(color: scheme.primary),
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
  });

  final String initial;
  final int level;
  final String? photoUrl;

  static const double _size = 52;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasPhoto = photoUrl != null && photoUrl!.trim().isNotEmpty;
    return SizedBox(
      width: _size + 4,
      height: _size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 2,
            top: 0,
            child: CircleAvatar(
              radius: _size / 2,
              backgroundColor: scheme.primary.withValues(alpha: 0.15),
              backgroundImage: hasPhoto ? NetworkImage(photoUrl!) : null,
              onBackgroundImageError: hasPhoto ? (_, __) {} : null,
              child: hasPhoto
                  ? null
                  : Text(
                      initial,
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
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
                border: Border.all(color: scheme.surface, width: 2),
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
