import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import 'auth_controller.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const SizedBox(height: 24),
                StudyCard(
                  eyebrow: 'ADAPTIVE MASTERY',
                  title: 'Sign in',
                  subtitle: 'Firebase proves who you are. Then you can see and extend the shared graph.',
                  footer: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _email,
                        decoration: const InputDecoration(labelText: 'Email', filled: true, fillColor: Color(0xFFFFFCF7)),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        decoration: const InputDecoration(labelText: 'Password', filled: true, fillColor: Color(0xFFFFFCF7)),
                        obscureText: true,
                      ),
                      const SizedBox(height: 16),
                      if (auth.loading)
                        const SizedBox(height: 48, child: PulsePlaceholder())
                      else
                        FilledButton(onPressed: () => auth.signIn(_email.text.trim(), _password.text), child: const Text('Sign in')),
                      if (auth.error != null) ...[
                        const SizedBox(height: 12),
                        Text(auth.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
