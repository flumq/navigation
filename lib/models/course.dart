import 'dart:math' as math;
import 'dart:ui' show Offset;
import '../services/calibration_service.dart';
import '../core/config.dart';
import '../core/geo.dart';

// =============================================================================
// 1. 코스 노선 (정규화 좌표 0~1)
// =============================================================================
final RouteGeometry kCourseRoute = RouteGeometry(const [
  Offset(0.6197, 0.0187), Offset(0.6327, 0.0231), Offset(0.6580, 0.0246),
  Offset(0.6740, 0.0283), Offset(0.6829, 0.0341), Offset(0.7165, 0.0398),
  Offset(0.7267, 0.0447), Offset(0.7370, 0.0431), Offset(0.7482, 0.0459),
  Offset(0.7532, 0.0516), Offset(0.7966, 0.0654), Offset(0.8214, 0.0764),
  Offset(0.8406, 0.0866), Offset(0.8714, 0.1114), Offset(0.8972, 0.1521),
  Offset(0.9088, 0.2215), Offset(0.9180, 0.3577), Offset(0.9336, 0.4612),
  Offset(0.9429, 0.4980), Offset(0.9547, 0.5894), Offset(0.9438, 0.6522),
  Offset(0.9131, 0.7270), Offset(0.9197, 0.7577), Offset(0.9130, 0.7655),
  Offset(0.8963, 0.7658), Offset(0.8930, 0.7598), Offset(0.8840, 0.7553),
  Offset(0.8308, 0.7524), Offset(0.7978, 0.7561), Offset(0.7802, 0.7639),
  Offset(0.7706, 0.7647), Offset(0.6415, 0.7577), Offset(0.6468, 0.6732),
  Offset(0.6410, 0.6471), Offset(0.6519, 0.6223), Offset(0.6640, 0.4497),
  Offset(0.6702, 0.4163), Offset(0.6734, 0.3116), Offset(0.6827, 0.2808),
  Offset(0.6776, 0.2605), Offset(0.6818, 0.1917), Offset(0.6542, 0.1847),
  Offset(0.6170, 0.1856), Offset(0.5833, 0.1803), Offset(0.4869, 0.1785),
  Offset(0.4107, 0.1699), Offset(0.4131, 0.1551), Offset(0.4265, 0.1303),
  Offset(0.4515, 0.0997), Offset(0.4743, 0.0793), Offset(0.5101, 0.0580),
  Offset(0.5380, 0.0460), Offset(0.5714, 0.0352), Offset(0.6165, 0.0297),
]);

// =============================================================================
// 2. 턴 종류 (TTS 내비 지원)
// =============================================================================
enum NavTurnKind {
  straight, slightLeft, slightRight, left, right,
  sharpLeft, sharpRight, uTurn, roundabout,
}

/// 음성/화면 공용 한국어 명칭. 기존엔 두 파일에 같은 switch가 있었다.
extension NavTurnKindLabel on NavTurnKind {
  String get label => switch (this) {
        NavTurnKind.left => '좌회전',
        NavTurnKind.right => '우회전',
        NavTurnKind.slightLeft => '좌측 방향',
        NavTurnKind.slightRight => '우측 방향',
        NavTurnKind.sharpLeft => '급좌회전',
        NavTurnKind.sharpRight => '급우회전',
        NavTurnKind.uTurn => '유턴',
        NavTurnKind.straight => '직진',
        NavTurnKind.roundabout => '회전교차로',
      };
}

class RoundaboutSpec {
  const RoundaboutSpec({
    required this.entryProgress,
    required this.exitProgress,
    required this.exitNumber,
    required this.clockDirection,
    this.exitLabel = '',
  });

  final double entryProgress, exitProgress;
  final int exitNumber, clockDirection;
  final String exitLabel;
}

/// 회전교차로 데이터. 현재 코스에는 없으므로 비어 있다.
/// 실제 교차로가 생기면 여기에 추가하면 된다.
const List<RoundaboutSpec> kRoundabouts = [];

class RouteTurn {
  const RouteTurn({
    required this.progress,
    required this.angleDeg,
    required this.kind,
    this.roundabout,
  });

  final double progress;
  final double angleDeg;
  final NavTurnKind kind;
  final RoundaboutSpec? roundabout;

  bool get rightTurn => angleDeg > 0;
  bool get isRoundabout => kind == NavTurnKind.roundabout;
}

// =============================================================================
// 3. 경로 기하
// =============================================================================
class RouteGeometry {
  RouteGeometry(this.points) {
    _cumulative.add(0);
    for (var i = 0; i < points.length - 1; i++) {
      final len = (points[i + 1] - points[i]).distance;
      _segmentLengths.add(len);
      _cumulative.add(_cumulative.last + len);
    }
    _total = _cumulative.last;
    _turns = _findTurns();
  }

  final List<Offset> points;
  final List<double> _segmentLengths = [];
  final List<double> _cumulative = [];
  late final double _total;
  late final List<RouteTurn> _turns;

  List<RouteTurn> get turns => List.unmodifiable(_turns);

  /// 진행률 [progress] 지점의 좌표.
  Offset pointAt(double progress) {
    final target = clamp01(progress) * _total;
    for (var i = 0; i < _segmentLengths.length; i++) {
      if (target <= _cumulative[i + 1] || i == _segmentLengths.length - 1) {
        final len = _segmentLengths[i];
        final t = len == 0 ? 0.0 : clamp01((target - _cumulative[i]) / len);
        return Offset.lerp(points[i], points[i + 1], t)!;
      }
    }
    return points.last;
  }

  /// 진행률 [progress] 지점에서 진행 방향에 수직으로 [lateral]만큼 오프셋한 좌표.
  /// 코스가 순환선이므로 2m 앞 지점은 누적거리 기반으로 계산한다.
  Offset positionWithOffset(double progress, double lateral) {
    final base = pointAt(progress);
    const deltaM = 2.0;
    final meters = clamp01(progress) * _total;
    final nextProgress = ((meters + deltaM) % _total) / _total;
    final dir = pointAt(nextProgress) - base;
    if (dir.distance == 0) return base;
    return base + Offset(-dir.dy, dir.dx) / dir.distance * lateral;
  }

  double distanceTo(Offset p) => project(p).distance;

  ({double progress, double distance}) project(Offset p) {
    final hit = _closest(p);
    return (progress: hit.progress, distance: hit.distance);
  }

  /// [fromProgress]에서 [windowM] 미터 이내의 구간에서만 가장 가까운 점을 찾는다.
  ({double progress, double distance})? projectNear(
    Offset p,
    double fromProgress,
    double windowM,
  ) {
    final hit = _closest(p, fromProgress: fromProgress, maxAlongM: windowM);
    if (!hit.found) return null;
    return (progress: hit.progress, distance: hit.distance);
  }

  ({double progress, double distance, bool found}) _closest(
    Offset p, {
    double? fromProgress,
    double? maxAlongM,
  }) {
    final totalM = AppConfig.routeLengthKm * 1000;
    var best = double.infinity;
    var bestProgress = fromProgress ?? 0.0;
    var found = false;

    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final ab = points[i + 1] - a;
      final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
      final ap = p - a;
      final t = lenSq == 0
          ? 0.0
          : clamp01((ap.dx * ab.dx + ap.dy * ab.dy) / lenSq);
      final q = a + ab * t;
      final prog = _total == 0
          ? 0.0
          : (_cumulative[i] + _segmentLengths[i] * t) / _total;

      if (fromProgress != null && maxAlongM != null) {
        if (circular01(fromProgress, prog) * totalM > maxAlongM) continue;
      }

      final d = mapDistanceM(p, q);
      if (d < best) {
        best = d;
        bestProgress = prog;
        found = true;
      }
    }
    return (
      progress: bestProgress,
      distance: found ? best : double.infinity,
      found: found,
    );
  }

  List<RouteTurn> _findTurns() {
    final out = <RouteTurn>[];
    for (var i = 1; i < points.length - 1; i++) {
      final a = points[i] - points[i - 1];
      final b = points[i + 1] - points[i];
      // 정규화 좌표를 픽셀 비율로 되돌려 실제 각도를 계산한다.
      final ax = a.dx * AppConfig.mapWidthPx;
      final ay = a.dy * AppConfig.mapHeightPx;
      final bx = b.dx * AppConfig.mapWidthPx;
      final by = b.dy * AppConfig.mapHeightPx;
      final angle =
          math.atan2(ax * by - ay * bx, ax * bx + ay * by) * 180 / math.pi;

      if (angle.abs() < AppConfig.turnMinAngleDeg) continue;

      final progress = _cumulative[i] / _total;
      RoundaboutSpec? ra;
      for (final spec in kRoundabouts) {
        if (progress >= spec.entryProgress - 0.005 &&
            progress <= spec.exitProgress + 0.005) {
          ra = spec;
          break;
        }
      }

      out.add(RouteTurn(
        progress: progress,
        angleDeg: angle,
        kind: ra != null ? NavTurnKind.roundabout : _classify(angle),
        roundabout: ra,
      ));
    }
    return out;
  }

  static NavTurnKind _classify(double angle) {
    final a = angle.abs();
    if (a < 45) return angle > 0 ? NavTurnKind.slightRight : NavTurnKind.slightLeft;
    if (a < 120) return angle > 0 ? NavTurnKind.right : NavTurnKind.left;
    if (a < 150) return angle > 0 ? NavTurnKind.sharpRight : NavTurnKind.sharpLeft;
    return NavTurnKind.uTurn;
  }

  /// 현재 진행률 이후 첫 번째 회전과 거리(m). 끝을 넘으면 처음 회전으로 돌아간다.
  ({RouteTurn? turn, double meters}) nextTurn(double progress) {
    if (_turns.isEmpty) return (turn: null, meters: 0);
    final p = clamp01(progress);
    final totalM = AppConfig.routeLengthKm * 1000;
    for (final t in _turns) {
      if (t.progress > p) return (turn: t, meters: (t.progress - p) * totalM);
    }
    final first = _turns.first;
    return (turn: first, meters: (1 - p + first.progress) * totalM);
  }
}

/// 진행률 [progress]에서의 진행 방향 각도(라디안). 지도 회전 표시에 쓴다.
double routeHeadingAt(RouteGeometry r, double progress) {
  final a = r.pointAt(progress);
  final b = r.pointAt((progress + 0.003) % 1.0);
  return math.atan2(
    (b.dy - a.dy) * AppConfig.mapHeightPx,
    (b.dx - a.dx) * AppConfig.mapWidthPx,
  );
}