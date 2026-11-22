import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Short, gentle SFX for quiz correct / incorrect answers.
class QuizFeedbackSounds {
  QuizFeedbackSounds._();

  static final AudioPlayer _player = AudioPlayer();
  static var _ready = false;

  static const _correctAsset = 'sounds/quiz_correct.wav';
  static const _incorrectAsset = 'sounds/quiz_incorrect.wav';

  static Future<void> _ensureReady() async {
    if (_ready) return;
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setPlayerMode(PlayerMode.lowLatency);
    // Ambient: mix with other audio and respect the silent switch.
    await _player.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
      ),
    );
    _ready = true;
  }

  static Future<void> play({required bool correct}) async {
    try {
      await _ensureReady();
      await _player.stop();
      await _player.play(
        AssetSource(correct ? _correctAsset : _incorrectAsset),
        volume: 0.55,
      );
    } catch (err, stack) {
      // Never block answering if audio fails (missing asset, web, etc.).
      debugPrint('QuizFeedbackSounds: $err\n$stack');
    }
  }
}
