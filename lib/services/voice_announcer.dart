import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/config.dart';
import '../models/course.dart';

enum VoicePriority { low, normal, high }

class NavAnnouncer {
  NavAnnouncer._();
  static final NavAnnouncer instance = NavAnnouncer._();

  final FlutterTts _tts = FlutterTts();
  final List<String> _queue = [];
  final Set<String> _fired = {};
  bool _ready = false;
  bool _enabled = true;
  bool _draining = false;
  bool _offRouteAnnounced = false;
  DateTime? _lastSpeedWarn;

  bool get enabled => _enabled;

  Future<void> init() async {
    try {
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      _ready = true;
    } catch (e) {
      debugPrint('TTS init 실패: $e');
    }
  }

  void setEnabled(bool v) {
    _enabled = v;
    if (!v) {
      _queue.clear();
      _tts.stop();
    }
  }

  /// 새 운행을 시작할 때 안내 상태를 초기화한다.
  void reset() {
    _fired.clear();
    _queue.clear();
    _offRouteAnnounced = false;
    _lastSpeedWarn = null;
    _tts.stop();
  }

  void say(String text, {VoicePriority priority = VoicePriority.normal}) {
    if (!_enabled || !_ready || text.isEmpty) return;
    if (priority == VoicePriority.high) {
      _queue.clear();
      _tts.stop();
    } else if (priority == VoicePriority.low && _draining) {
      return; // 말하는 중이면 낮은 우선순위는 버린다.
    }
    _queue.add(text);
    if (_queue.length > 2) _queue.removeAt(0);
    if (!_draining) _drain();
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty && _enabled) {
        final msg = _queue.removeAt(0);
        try {
          await _tts
              .speak(msg)
              .timeout(const Duration(seconds: 8), onTimeout: () {});
        } catch (e) {
          debugPrint('TTS 발화 실패: $e');
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// `GpsDriveTracker`, `VehicleSimulator`의 onLap 콜백으로 연결한다.
  void onLap(int laps) => say('$laps바퀴를 완주했습니다');

  /// 💡 개편된 위·경도·미터 기반 RouteGeometry와 호환되도록 체크 로직 정돈
  void checkTurn(
      {required double currentMeters, required RouteGeometry route}) {
    if (!_enabled) return;

    // 신규 미터 기반 nextTurnAtDistance 호출
    final next = route.nextTurnAtDistance(currentMeters);
    final t = next.turn;
    if (t == null) return;

    final key = '${t.distanceMeters.round()}';
    const thresholds = [300.0, 100.0, 30.0];

    for (final d in thresholds) {
      final k = '${key}_${d.toInt()}';
      if (next.distanceToTurnMeters < d && !_fired.contains(k)) {
        // 더 가까운 단계를 울렸다면 그보다 먼 단계는 함께 소진한다.
        for (final d2 in thresholds) {
          if (d2 >= d) _fired.add('${key}_${d2.toInt()}');
        }
        final msg = _buildTurnMessage(t, next.distanceToTurnMeters, d);
        if (msg != null) say(msg);
        return;
      }
    }
  }

  String? _buildTurnMessage(RouteTurn t, double meters, double threshold) {
    final verb = t.kind.label;
    if (threshold >= 300) return '잠시 후 $verb입니다';
    if (threshold >= 100) return '${meters.round()}미터 앞, $verb입니다';
    return verb;
  }

  void checkSpeed(double speedKmh) {
    if (!_enabled || speedKmh <= AppConfig.speedLimitKmh) return;
    final now = DateTime.now();
    if (_lastSpeedWarn != null &&
        now.difference(_lastSpeedWarn!).inSeconds < 6) {
      return;
    }
    _lastSpeedWarn = now;
    say('제한속도 초과입니다. 속도를 줄이세요');
  }

  void checkOffRoute(bool isOffRoute) {
    if (!_enabled) return;
    if (isOffRoute && !_offRouteAnnounced) {
      _offRouteAnnounced = true;
      say('경로를 벗어났습니다. 코스로 복귀하세요', priority: VoicePriority.high);
    } else if (!isOffRoute && _offRouteAnnounced) {
      _offRouteAnnounced = false;
      say('경로로 복귀했습니다', priority: VoicePriority.high);
    }
  }
}
