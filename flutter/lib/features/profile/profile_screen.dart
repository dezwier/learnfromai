import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/study_card.dart';
import '../auth/auth_controller.dart';
import 'account_settings_sheet.dart';
import 'profile_hud.dart';

/// Fullscreen profile overlay with settings, logout, and learning placeholders.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final user = auth.user;
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => showAccountSettingsSheet(context),
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    label: const Text('Settings'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await auth.signOut();
                      onClose();
                    },
                    icon: const Icon(Icons.logout, size: 20),
                    label: const Text('Logout'),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: studyPagePadding,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 32,
                            backgroundColor: scheme.primary.withValues(alpha: 0.15),
                            backgroundImage: (user?.photoUrl?.trim().isNotEmpty == true)
                                ? NetworkImage(user!.photoUrl!)
                                : null,
                            child: (user?.photoUrl?.trim().isNotEmpty == true)
                                ? null
                                : Text(
                                    user?.initial ?? 'L',
                                    style: TextStyle(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 24,
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user?.hudName ?? 'Learner',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Learner · Level ${ProfileHud.placeholderLevel}',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: scheme.onSurface.withValues(alpha: 0.7),
                                      ),
                                ),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: ProfileHud.placeholderNextXp > 0
                                        ? ProfileHud.placeholderXp / ProfileHud.placeholderNextXp
                                        : 1,
                                    minHeight: 6,
                                    backgroundColor: scheme.outline.withValues(alpha: 0.2),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${ProfileHud.placeholderXp} / ${ProfileHud.placeholderNextXp} XP',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const StudyCard(
                    eyebrow: 'LEARNING',
                    title: 'Progress',
                    subtitle: 'Mastery streaks and topic completion will show up here.',
                  ),
                  const SizedBox(height: 12),
                  const StudyCard(
                    eyebrow: 'TOPICS',
                    title: 'Recent study',
                    subtitle: 'Recently opened topics will appear here as placeholders for now.',
                  ),
                  const SizedBox(height: 12),
                  const StudyCard(
                    eyebrow: 'PRACTICE',
                    title: 'Coming soon',
                    subtitle: 'Quizzes and spaced review will live on this profile.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
