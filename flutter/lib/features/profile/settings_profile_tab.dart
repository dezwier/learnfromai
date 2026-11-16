import 'dart:typed_data';

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
    this.photoBytes,
    required this.onPickPhoto,
    required this.onClearPhoto,
    this.photoBusy = false,
  });

  final UserProfile user;
  final TextEditingController usernameController;
  final TextEditingController fullNameController;
  final String? photoUrl;
  final Uint8List? photoBytes;
  final VoidCallback onPickPhoto;
  final VoidCallback onClearPhoto;
  final bool photoBusy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasPhoto = (photoBytes != null && photoBytes!.isNotEmpty) ||
        (photoUrl != null && photoUrl!.trim().isNotEmpty);
    ImageProvider? image;
    if (photoBytes != null && photoBytes!.isNotEmpty) {
      image = MemoryImage(photoBytes!);
    } else if (photoUrl != null &&
        photoUrl!.trim().isNotEmpty &&
        (photoUrl!.startsWith('http://') || photoUrl!.startsWith('https://'))) {
      image = NetworkImage(photoUrl!);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTap: photoBusy ? null : onPickPhoto,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircleAvatar(
                      radius: 36,
                      backgroundColor: scheme.primary.withValues(alpha: 0.15),
                      backgroundImage: image,
                      onBackgroundImageError: image != null ? (_, _) {} : null,
                      child: image == null
                          ? Text(
                              user.initial,
                              style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 28,
                              ),
                            )
                          : null,
                    ),
                    if (photoBusy)
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: photoBusy ? null : onPickPhoto,
                child: const Text('Change photo'),
              ),
              if (hasPhoto)
                TextButton(
                  onPressed: photoBusy ? null : onClearPhoto,
                  child: const Text('Remove photo'),
                ),
              Text(
                'Upload a photo from your library.',
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
