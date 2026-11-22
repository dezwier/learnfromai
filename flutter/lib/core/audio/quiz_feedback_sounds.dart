import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Short, gentle SFX for quiz correct / incorrect answers.
class QuizFeedbackSounds {
  QuizFeedbackSounds._();

  static AudioPlayer? _player;
  static Future<AudioPlayer>? _init;
  static Uint8List? _correctBytes;
  static Uint8List? _incorrectBytes;

  static const _correctPath = 'assets/sounds/quiz_correct.wav';
  static const _incorrectPath = 'assets/sounds/quiz_incorrect.wav';

  static Future<AudioPlayer> _playerReady() {
    final existing = _init;
    if (existing != null) return existing;
    final future = _createPlayer();
    _init = future;
    return future;
  }

  static Future<AudioPlayer> _createPlayer() async {
    // Playback category: hear SFX even with the iPhone mute switch on.
    await AudioPlayer.global.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.duckOthers,
          },
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    );
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    await player.setPlayerMode(PlayerMode.mediaPlayer);
    await player.setVolume(1.0);
    _correctBytes = (await rootBundle.load(_correctPath)).buffer.asUint8List();
    _incorrectBytes = (await rootBundle.load(_incorrectPath)).buffer.asUint8List();
    _player = player;
    return player;
  }

  static Future<void> play({required bool correct}) async {
    try {
      final player = await _playerReady();
      final bytes = correct ? _correctBytes : _incorrectBytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Quiz feedback sound bytes missing');
      }
      await player.stop();
      // BytesSource avoids AssetSource/cache path issues on iOS release builds.
      await player.play(BytesSource(bytes), volume: 1.0);
    } catch (err, stack) {
      _init = null;
      _player = null;
      _correctBytes = null;
      _incorrectBytes = null;
      debugPrint('QuizFeedbackSounds: $err\n$stack');
    }
  }
}
