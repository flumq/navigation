import '../core/config.dart';
import '../core/geo.dart';
import '../models/vehicle.dart';

/// 최근 N초 평균속도.
class SpeedWindow {
  final _hist = <({DateTime t, double kmh})>[];

  void add(double kmh, DateTime now) {
    _hist.add((t: now, kmh: kmh));
    _hist.removeWhere(
        (e) => now.difference(e.t).inSeconds > AppConfig.avgSpeedWindowSec);
  }

  double get average {
    if (_hist.isEmpty) return 0;
    var sum = 0.0;
    for (final e in _hist) {
      sum += e.kmh;
    }
    return sum / _hist.length;
  }

  void clear() => _hist.clear();
}

/// 진행률이 0.8 이상에서 0.2 미만으로 떨어지면 한 바퀴 완주로 본다.
class LapCounter {
  LapCounter({this.onLap});

  /// 완주할 때마다 누적 랩 수와 함께 호출된다.
  final void Function(int laps)? onLap;

  double? _last;
  int laps = 0;

  void update(double progress) {
    final prev = _last;
    if (prev != null && prev > 0.8 && progress < 0.2) {
      laps++;
      onLap?.call(laps);
    }
    _last = progress;
  }

  void reset() {
    _last = null;
    laps = 0;
  }
}

/// 마지막 점에서 [AppConfig.trailMinStepM] 이상 떨어졌을 때만 기록한다.
class TrailRecorder {
  final _pts = <TrailPoint>[];

  List<TrailPoint> get points => List.unmodifiable(_pts);

  void maybeAdd(double lat, double lon, DateTime now) {
    if (_pts.isNotEmpty &&
        haversineM(_pts.last.lat, _pts.last.lon, lat, lon) <
            AppConfig.trailMinStepM) {
      return;
    }
    _pts.add(TrailPoint(lat: lat, lon: lon, ms: now.millisecondsSinceEpoch));
    if (_pts.length > AppConfig.trailMaxPoints) _pts.removeAt(0);
  }

  void clear() => _pts.clear();
}

/// 이탈 판정 히스테리시스.
/// 임계 거리를 [AppConfig.offRouteConfirmSeconds]초 이상 넘어야 이탈로 확정한다.
class OffRouteTracker {
  double _seconds = 0;

  bool get isOff => _seconds >= AppConfig.offRouteConfirmSeconds;

  /// 갱신 후 이탈 여부를 반환한다.
  bool update({
    required double distanceM,
    required double thresholdM,
    required double dtSec,
  }) {
    _seconds = distanceM > thresholdM ? _seconds + dtSec : 0;
    return isOff;
  }

  void reset() => _seconds = 0;
}

/// 차량 한 대의 주행 기록을 묶은 객체.
class DriveTelemetry {
  DriveTelemetry({void Function(int laps)? onLap})
      : _laps = LapCounter(onLap: onLap);

  final SpeedWindow _speed = SpeedWindow();
  final LapCounter _laps;
  final TrailRecorder _trail = TrailRecorder();
  final OffRouteTracker offRoute = OffRouteTracker();

  double get avgSpeedKmh => _speed.average;
  int get laps => _laps.laps;
  List<TrailPoint> get trail => _trail.points;

  /// 매 틱(또는 GPS 한 번) 호출한다.
  void record({
    required double progress,
    required double speedKmh,
    required double lat,
    required double lon,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    _speed.add(speedKmh, t);
    _laps.update(progress);
    _trail.maybeAdd(lat, lon, t);
  }

  void reset() {
    _speed.clear();
    _laps.reset();
    _trail.clear();
    offRoute.reset();
  }
}

/// 두 차량 간 시간 계산용 속도.
/// 평균 → 순간속도(A) → 순간속도(B) → 순항속도 순서로 폴백한다.
double headwaySpeedKmh({
  required double avgA,
  required double avgB,
  required double instA,
  required double instB,
}) {
  final avg = (avgA + avgB) / 2;
  if (avg >= 3) return avg;
  if (instA >= 3) return instA;
  if (instB >= 3) return instB;
  return AppConfig.busCruiseKmh;
}