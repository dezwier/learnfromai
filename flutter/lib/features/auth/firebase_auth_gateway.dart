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
}
