import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Short, gentle SFX + haptics for quiz correct / incorrect answers.
///
/// Uses [AssetSource] (not BytesSource — unimplemented on iOS) and the media
/// volume stream on both platforms.
class QuizFeedbackSounds {
  QuizFeedbackSounds._();

  static Future<AudioPlayer>? _init;

  static const _correctAsset = 'sounds/quiz_correct.wav';
  static const _incorrectAsset = 'sounds/quiz_incorrect.wav';

  static Future<AudioPlayer> _playerReady() {
    final existing = _init;
    if (existing != null) return existing;
    final future = _createPlayer();
    _init = future;
    return future;
  }

  static Future<AudioPlayer> _createPlayer() async {
    // Media / playback stream so hardware volume buttons control these SFX.
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
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    );
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    await player.setPlayerMode(PlayerMode.mediaPlayer);
    await player.setVolume(1.0);
    // Also set on the instance — some platforms ignore the global context alone.
    await player.setAudioContext(
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
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    );
    return player;
  }

  static void _haptic({required bool correct}) {
    // Correct: soft success tap. Incorrect: lighter selection tick — both subtle.
    if (correct) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.selectionClick();
    }
  }

  static Future<void> play({required bool correct}) async {
    _haptic(correct: correct);
    try {
      final player = await _playerReady();
      final asset = correct ? _correctAsset : _incorrectAsset;
      await player.stop();
      await player.play(AssetSource(asset), volume: 1.0);
    } catch (err, stack) {
      _init = null;
      debugPrint('QuizFeedbackSounds: $err\n$stack');
    }
  }
}
