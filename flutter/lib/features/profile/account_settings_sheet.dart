import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import 'settings_account_tab.dart';
import 'settings_app_tab.dart';
import 'settings_profile_tab.dart';

Future<void> showAccountSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => const AccountSettingsSheet(),
  );
}

class AccountSettingsSheet extends StatefulWidget {
  const AccountSettingsSheet({super.key});

  @override
  State<AccountSettingsSheet> createState() => _AccountSettingsSheetState();
}

class _AccountSettingsSheetState extends State<AccountSettingsSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _username = TextEditingController();
  final _fullName = TextEditingController();
  final _email = TextEditingController();
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  String? _photoUrl;
  var _saving = false;
  String? _error;
  var _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      setState(() => _tabIndex = _tabs.index);
    });
    final user = context.read<AuthController>().user;
    _username.text = user?.username ?? '';
    _fullName.text = user?.fullName ?? user?.displayName ?? '';
    _email.text = user?.email ?? '';
    _photoUrl = user?.photoUrl;
  }

  @override
  void dispose() {
    _tabs.dispose();
    _username.dispose();
    _fullName.dispose();
    _email.dispose();
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  bool get _showSave => _tabIndex == 1 || _tabIndex == 2;

  Future<void> _save() async {
    final auth = context.read<AuthController>();
    final user = auth.user;
    if (user == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_tabIndex == 1) {
        await auth.updateProfile(
          username: _username.text.trim(),
          fullName: _fullName.text.trim(),
          photoUrl: _photoUrl?.trim() ?? '',
        );
      } else if (_tabIndex == 2) {
        final next = _newPassword.text;
        final confirm = _confirmPassword.text;
        if (next.isNotEmpty && next != confirm) {
          throw StateError('New passwords do not match');
        }
        await auth.updateAccount(
          email: _email.text.trim(),
          currentPassword: _currentPassword.text,
          newPassword: next.isEmpty ? null : next,
        );
        _currentPassword.clear();
        _newPassword.clear();
        _confirmPassword.clear();
        await auth.loadMe();
      }
      if (mounted) Navigator.of(context).pop();
    } catch (exc) {
      setState(() => _error = exc.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickPhotoUrl() async {
    final controller = TextEditingController(text: _photoUrl ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Photo URL'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'https://…'),
            autofocus: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Use'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (value == null) return;
    setState(() => _photoUrl = value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = context.watch<AuthController>().user;
    final height = MediaQuery.sizeOf(context).height * 0.85;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabs,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.6),
            tabAlignment: TabAlignment.fill,
            tabs: const [
              Tab(text: 'App'),
              Tab(text: 'Profile'),
              Tab(text: 'Account'),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                const SettingsAppTab(),
                if (user == null)
                  const Center(child: Text('Sign in to edit profile'))
                else
                  SettingsProfileTab(
                    user: user,
                    usernameController: _username,
                    fullNameController: _fullName,
                    photoUrl: _photoUrl,
                    onPickPhoto: _pickPhotoUrl,
                    onClearPhoto: () => setState(() => _photoUrl = null),
                  ),
                SettingsAccountTab(
                  emailController: _email,
                  currentPasswordController: _currentPassword,
                  newPasswordController: _newPassword,
                  confirmPasswordController: _confirmPassword,
                ),
              ],
            ),
          ),
          if (_showSave)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
