abstract class AuthGateway {
  Future<void> signIn(String email, String password);
  Future<String?> idToken({bool forceRefresh = false});
  Future<void> signOut();
  Future<void> updateEmail(String email);
  Future<void> updatePassword(String newPassword);
  Future<void> reauthenticate({required String email, required String password});
}

class UnavailableAuthGateway implements AuthGateway {
  @override
  Future<String?> idToken({bool forceRefresh = false}) async => null;

  @override
  Future<void> signIn(String email, String password) async {
    throw StateError('Firebase is not configured for this build');
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<void> updateEmail(String email) async {
    throw StateError('Firebase is not configured for this build');
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    throw StateError('Firebase is not configured for this build');
  }

  @override
  Future<void> reauthenticate({required String email, required String password}) async {
    throw StateError('Firebase is not configured for this build');
  }
}
