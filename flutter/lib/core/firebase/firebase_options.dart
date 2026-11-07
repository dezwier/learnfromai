import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Replace this file with the output of `flutterfire configure` for a new
/// Firebase project. These placeholder values are not copied from another app.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    return DefaultFirebaseOptions._native;
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'demo-web-key',
    appId: '1:000000000000:web:adaptivemastery',
    messagingSenderId: '000000000000',
    projectId: 'adaptive-mastery-dev',
    authDomain: 'adaptive-mastery-dev.firebaseapp.com',
  );

  static const FirebaseOptions _native = FirebaseOptions(
    apiKey: 'AIzaSyC0Foafxq4PBkBeJAnHjU4B1qGHT2xRfRc',
    appId: '1:124258867891:ios:f28935ec372d0734962ec6',
    messagingSenderId: '124258867891',
    projectId: 'learnfromai',
    storageBucket: 'learnfromai.firebasestorage.app',
    iosBundleId: 'app.adaptivemastery.adaptiveMastery',
  );
}
