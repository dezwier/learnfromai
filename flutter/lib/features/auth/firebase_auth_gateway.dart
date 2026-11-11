import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../../core/firebase/firebase_options.dart';
import 'auth_gateway.dart';

class FirebaseAuthGateway implements AuthGateway {
  bool _ready = false;

  Future<void> _ensure() async {
    if (_ready) return;
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    _ready = true;
  }

  User _requireUser() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Not signed in');
    return user;
  }

  @override
  Future<void> signIn(String email, String password) async {
    await _ensure();
    await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
  }

  @override
  Future<String?> idToken({bool forceRefresh = false}) async {
    await _ensure();
    return FirebaseAuth.instance.currentUser?.getIdToken(forceRefresh);
  }

  @override
  Future<void> signOut() async {
    if (!_ready) return;
    await FirebaseAuth.instance.signOut();
  }

  @override
  Future<void> reauthenticate({required String email, required String password}) async {
    await _ensure();
    final user = _requireUser();
    final credential = EmailAuthProvider.credential(email: email, password: password);
    await user.reauthenticateWithCredential(credential);
  }

  @override
  Future<void> updateEmail(String email) async {
    await _ensure();
    final user = _requireUser();
    await user.verifyBeforeUpdateEmail(email);
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    await _ensure();
    final user = _requireUser();
    await user.updatePassword(newPassword);
  }
}
