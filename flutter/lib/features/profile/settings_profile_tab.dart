import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'settings_form_styles.dart';

class SettingsProfileTab extends StatelessWidget {
  const SettingsProfileTab({
    super.key,
    required this.user,
    required this.usernameController,
    required this.fullNameController,
    required this.photoUrl,
    required this.onPickPhoto,
    required this.onClearPhoto,
  });

  final UserProfile user;
  final TextEditingController usernameController;
  final TextEditingController fullNameController;
  final String? photoUrl;
  final VoidCallback onPickPhoto;
  final VoidCallback onClearPhoto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasPhoto = photoUrl != null && photoUrl!.trim().isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTap: onPickPhoto,
                child: CircleAvatar(
                  radius: 36,
                  backgroundColor: scheme.primary.withValues(alpha: 0.15),
                  backgroundImage: hasPhoto ? NetworkImage(photoUrl!) : null,
                  onBackgroundImageError: hasPhoto ? (_, __) {} : null,
                  child: hasPhoto
                      ? null
                      : Text(
                          user.initial,
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 28,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: onPickPhoto,
                child: const Text('Change photo'),
              ),
              if (hasPhoto)
                TextButton(
                  onPressed: onClearPhoto,
                  child: const Text('Remove photo'),
                ),
              Text(
                'Paste an image URL for now — uploads come later.',
                style: SettingsFormStyles.finePrintStyle(context),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: usernameController,
          textInputAction: TextInputAction.next,
          decoration: SettingsFormStyles.fieldDecoration(context, labelText: 'Username'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: fullNameController,
          textInputAction: TextInputAction.done,
          decoration: SettingsFormStyles.fieldDecoration(context, labelText: 'Full name'),
        ),
      ],
    );
  }
}
