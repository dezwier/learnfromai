# ADR 003 — Firebase exchange for an API JWT

Flutter signs in with Firebase Auth and posts the ID token to `POST /api/v1/auth/firebase`. The API verifies it with Firebase Admin and returns a PyJWT whose `sub` is the user id. Later requests use that bearer token. A 401 refreshes the Firebase ID token once and exchanges it again.

There is no email/password table. Tests create users and mint JWTs directly. The mobile and web clients store the API JWT with `flutter_secure_storage`, which is a deliberate change from the reference apps' SharedPreferences.
