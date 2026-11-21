import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../auth/auth_controller.dart';
import '../knowledge_graph/graph_controller.dart';
import 'settings_cron_overview.dart';
import 'settings_form_styles.dart';

class SettingsAppTab extends StatelessWidget {
  const SettingsAppTab({super.key});

  @override
  Widget build(BuildContext context) {
    final themes = context.watch<ThemeController>();
    final graph = context.watch<GraphController>();
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);
    final outline = SettingsFormStyles.outlineBorder(context);
    final isAdmin = auth.user?.isAdmin == true;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        SettingsFormStyles.settingsRow(
          context: context,
          label: 'Appearance',
          description: 'Choose light, dark, or match your device.',
          control: SettingsFormStyles.densePopupField<ThemeMode>(
            context: context,
            outlineBorder: outline,
            selectedChild: Text(
              switch (themes.mode) {
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
                ThemeMode.system => 'Device',
              },
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
            entries: [
              DensePopupEntry(
                value: ThemeMode.light,
                child: Text('Light', style: theme.textTheme.bodyMedium),
              ),
              DensePopupEntry(
                value: ThemeMode.dark,
                child: Text('Dark', style: theme.textTheme.bodyMedium),
              ),
              DensePopupEntry(
                value: ThemeMode.system,
                child: Text('Device', style: theme.textTheme.bodyMedium),
              ),
            ],
            onSelected: (mode) {
              if (mode != null) themes.setMode(mode);
            },
          ),
        ),
        const SizedBox(height: 16),
        SettingsFormStyles.settingsRow(
          context: context,
          label: 'AI provider',
          description: 'Which model backend generates neighborhoods and learning bits.',
          control: SettingsFormStyles.densePopupField<String>(
            context: context,
            outlineBorder: outline,
            selectedChild: Text(
              LlmProviderPref.label(graph.llmProvider),
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
            entries: [
              DensePopupEntry(
                value: LlmProviderPref.openai,
                child: Text('ChatGPT', style: theme.textTheme.bodyMedium),
              ),
              DensePopupEntry(
                value: LlmProviderPref.gemini,
                child: Text('Gemini', style: theme.textTheme.bodyMedium),
              ),
            ],
            onSelected: (value) {
              if (value != null) graph.saveLlmProvider(value);
            },
          ),
        ),
        if (isAdmin) ...[
          const SizedBox(height: 28),
          const SettingsCronOverview(),
        ],
      ],
    );
  }
}
