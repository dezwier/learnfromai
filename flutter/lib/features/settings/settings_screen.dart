import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../auth/auth_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final themes = context.watch<ThemeController>();
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: scheme.outline.withValues(alpha: theme.brightness == Brightness.light ? 0.3 : 0.5)),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        Text('Appearance', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Light, dark, or follow this device. Saved for this account.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<ThemeMode>(
          initialValue: themes.mode,
          decoration: InputDecoration(border: border, enabledBorder: border, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          items: const [
            DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
            DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
            DropdownMenuItem(value: ThemeMode.system, child: Text('Device')),
          ],
          onChanged: (value) {
            if (value != null) themes.setMode(value);
          },
        ),
        const SizedBox(height: 28),
        Text('Account', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(context.watch<AuthController>().user?.displayName ?? '', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () async {
              await context.read<AuthController>().signOut();
              if (context.mounted) context.go('/sign-in');
            },
            child: const Text('Log out'),
          ),
        ),
      ],
    );
  }
}
