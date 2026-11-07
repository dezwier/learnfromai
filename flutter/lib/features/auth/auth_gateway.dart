abstract class AuthGateway {
  Future<void> signIn(String email, String password);
  Future<String?> idToken({bool forceRefresh = false});
  Future<void> signOut();
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
}
