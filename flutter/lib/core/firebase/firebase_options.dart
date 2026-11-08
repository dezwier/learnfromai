import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Web and iOS both use this app's `learnfromai` Firebase project.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    return DefaultFirebaseOptions._native;
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBiV6IFtYTw9pr2EfHoUwaZ_F2rSTPwBgQ',
    appId: '1:124258867891:web:fd961c4464c1bb0f962ec6',
    messagingSenderId: '124258867891',
    projectId: 'learnfromai',
    authDomain: 'learnfromai.firebaseapp.com',
    storageBucket: 'learnfromai.firebasestorage.app',
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
