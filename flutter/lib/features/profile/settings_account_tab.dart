import 'package:flutter/material.dart';

import 'settings_form_styles.dart';

class SettingsAccountTab extends StatelessWidget {
  const SettingsAccountTab({
    super.key,
    required this.emailController,
    required this.currentPasswordController,
    required this.newPasswordController,
    required this.confirmPasswordController,
  });

  final TextEditingController emailController;
  final TextEditingController currentPasswordController;
  final TextEditingController newPasswordController;
  final TextEditingController confirmPasswordController;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Text(
          'Email and password',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Changing email or password requires your current password.',
          style: SettingsFormStyles.finePrintStyle(context),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: SettingsFormStyles.fieldDecoration(context, labelText: 'Email'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: currentPasswordController,
          obscureText: true,
          decoration: SettingsFormStyles.fieldDecoration(context, labelText: 'Current password'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: newPasswordController,
          obscureText: true,
          decoration: SettingsFormStyles.fieldDecoration(context, labelText: 'New password'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: confirmPasswordController,
          obscureText: true,
          decoration: SettingsFormStyles.fieldDecoration(context, labelText: 'Confirm new password'),
        ),
      ],
    );
  }
}
