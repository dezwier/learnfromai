import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../knowledge_graph/graph_controller.dart';
import 'settings_form_styles.dart';

class SettingsAppTab extends StatelessWidget {
  const SettingsAppTab({super.key});

  @override
  Widget build(BuildContext context) {
    final themes = context.watch<ThemeController>();
    final graph = context.watch<GraphController>();
    final theme = Theme.of(context);
    final outline = SettingsFormStyles.outlineBorder(context);
    final prefs = graph.prefs;

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
        const SizedBox(height: 28),
        Text(
          'Neighborhood size',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'How many related topics to fetch around a focus.',
          style: SettingsFormStyles.finePrintStyle(context),
        ),
        const SizedBox(height: 16),
        SettingsFormStyles.settingsRow(
          context: context,
          label: 'Parents',
          description: 'Broader topics above the focus.',
          controlWidth: 120,
          control: SettingsFormStyles.stepperControl(
            value: prefs.parents,
            min: 1,
            max: 2,
            onChanged: (value) => graph.savePreferences(prefs.copyWith(parents: value)),
          ),
        ),
        const SizedBox(height: 16),
        SettingsFormStyles.settingsRow(
          context: context,
          label: 'Siblings',
          description: 'Peer topics beside the focus.',
          controlWidth: 120,
          control: SettingsFormStyles.stepperControl(
            value: prefs.siblings,
            min: 2,
            max: 3,
            onChanged: (value) => graph.savePreferences(prefs.copyWith(siblings: value)),
          ),
        ),
        const SizedBox(height: 16),
        SettingsFormStyles.settingsRow(
          context: context,
          label: 'Children',
          description: 'Narrower topics below the focus.',
          controlWidth: 120,
          control: SettingsFormStyles.stepperControl(
            value: prefs.children,
            min: 3,
            max: 5,
            onChanged: (value) => graph.savePreferences(prefs.copyWith(children: value)),
          ),
        ),
        const SizedBox(height: 16),
        SettingsFormStyles.settingsRow(
          context: context,
          label: 'Related',
          description: 'Acquaintance topics farther out.',
          controlWidth: 120,
          control: SettingsFormStyles.stepperControl(
            value: prefs.acquaintances,
            min: 3,
            max: 5,
            onChanged: (value) => graph.savePreferences(prefs.copyWith(acquaintances: value)),
          ),
        ),
      ],
    );
  }
}
