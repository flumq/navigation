import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import '../core/config.dart';
import '../core/geo.dart';

// =============================================================================
// 1. 코스 노선 (실제 화성 시험장 일대 위·경도 좌표 리스트)
// =============================================================================
/// 0~1 정규화 픽셀 좌표 대신 실제 지구 위·경도(LatLng) 좌표 목록을 사용합니다.
final RouteGeometry kCourseRoute = RouteGeometry(const [
  LatLng(37.23150, 126.77950),
  LatLng(37.23180, 126.77980),
  LatLng(37.23230, 126.78050),
  LatLng(37.23270, 126.78120),
  LatLng(37.23310, 126.78200),
  LatLng(37.23350, 126.78310),
  LatLng(37.23380, 126.78420),
  LatLng(37.23400, 126.78500),
  LatLng(37.23360, 126.78610),
  LatLng(37.23300, 126.78700),
  LatLng(37.23200, 126.78750),
  LatLng(37.23100, 126.78720),
  LatLng(37.23000, 126.78650),
  LatLng(37.22900, 126.78520),
  LatLng(37.22850, 126.78380),
  LatLng(37.22830, 126.78210),
  LatLng(37.22860, 126.78080),
  LatLng(37.22920, 126.77990),
  LatLng(37.23020, 126.77940),
  LatLng(37.23150, 126.77950), // 순환 코스 종점(시작점 복귀)
]);

// =============================================================================
// 2. 턴 종류 (TTS 및 내비게이션 안내)
// =============================================================================
enum NavTurnKind {
  straight,
  slightLeft,
  slightRight,
  left,
  right,
  sharpLeft,
  sharpRight,
  uTurn,
  roundabout,
}

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

class RouteTurn {
  const RouteTurn({
    required this.distanceMeters,
    required this.angleDeg,
    required this.kind,
    required this.position,
  });

  final double distanceMeters;
  final double angleDeg;
  final NavTurnKind kind;
  final LatLng position;

  bool get rightTurn => angleDeg > 0;
}

// =============================================================================
// 3. 실제 위·경도 기반 코스 기하 연산 엔진 (RouteGeometry)
// =============================================================================
class RouteGeometry {
  RouteGeometry(this.points) {
    _cumulativeMeters.add(0.0);
    const distanceCalc = Distance();

    for (var i = 0; i < points.length - 1; i++) {
      // Haversine 공식을 사용해 실제 지점 간 거리(미터) 계산
      final len = distanceCalc.as(LengthUnit.Meter, points[i], points[i + 1]);
      _segmentLengthsMeters.add(len);
      _cumulativeMeters.add(_cumulativeMeters.last + len);
    }
    _totalMeters = _cumulativeMeters.last;
    _turns = _findTurns();
  }

  final List<LatLng> points;
  final List<double> _segmentLengthsMeters = [];
  final List<double> _cumulativeMeters = [];
  late final double _totalMeters;
  late final List<RouteTurn> _turns;

  double get totalMeters => _totalMeters;
  double get totalKm => _totalMeters / 1000.0;
  List<RouteTurn> get turns => List.unmodifiable(_turns);

  /// 누적 이동 거리(m) 지점의 실제 위·경도 좌표 산출
  LatLng pointAtDistance(double meters) {
    final targetMeters = meters.clamp(0.0, _totalMeters);
    for (var i = 0; i < _segmentLengthsMeters.length; i++) {
      if (targetMeters <= _cumulativeMeters[i + 1] || i == _segmentLengthsMeters.length - 1) {
        final len = _segmentLengthsMeters[i];
        final t = len == 0 ? 0.0 : (targetMeters - _cumulativeMeters[i]) / len;
        
        final lat = points[i].latitude + (points[i + 1].latitude - points[i].latitude) * t;
        final lon = points[i].longitude + (points[i + 1].longitude - points[i].longitude) * t;
        return LatLng(lat, lon);
      }
    }
    return points.last;
  }

  /// 0.0~1.0 비율 진행률 기반 좌표 반환 (하위 호환용)
  LatLng pointAt(double progress) {
    return pointAtDistance(clamp01(progress) * _totalMeters);
  }

  /// 현재 위치(LatLng)에서 가장 가까운 코스 상의 위치와 누적 이격 거리(m)를 도출
  ({double distanceMeters, double offRouteDistanceMeters, LatLng closestPoint}) projectLatLng(LatLng pos) {
    const distanceCalc = Distance();
    var minOffDistance = double.infinity;
    var bestCumulativeMeters = 0.0;
    var bestPoint = points.first;

    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];

      // 두 위경도 선분 위에 현재 좌표 투영
      final segLen = _segmentLengthsMeters[i];
      if (segLen == 0) continue;

      final dAB = distanceCalc.as(LengthUnit.Meter, a, b);
      final dAP = distanceCalc.as(LengthUnit.Meter, a, pos);
      final dBP = distanceCalc.as(LengthUnit.Meter, b, pos);

      // 간단한 삼각 수선 투영 근사
      double t = 0.0;
      if (dAB > 0) {
        t = ((dAP * dAP - dBP * dBP + dAB * dAB) / (2 * dAB * dAB)).clamp(0.0, 1.0);
      }

      final projLat = a.latitude + (b.latitude - a.latitude) * t;
      final projLon = a.longitude + (b.longitude - a.longitude) * t;
      final projPt = LatLng(projLat, projLon);

      final offDist = distanceCalc.as(LengthUnit.Meter, pos, projPt);
      if (offDist < minOffDistance) {
        minOffDistance = offDist;
        bestCumulativeMeters = _cumulativeMeters[i] + (segLen * t);
        bestPoint = projPt;
      }
    }

    return (
      distanceMeters: bestCumulativeMeters,
      offRouteDistanceMeters: minOffDistance,
      closestPoint: bestPoint,
    );
  }

  /// 💡 [핵심] 실제 잔여 거리(m)와 차량의 실시간 속도(km/h) 기반 남은 소요 시간(초/분) 계산
  ({double remainingMeters, double remainingKm, int estimatedSeconds, int estimatedMinutes}) calculateETA({
    required double currentMeters,
    required double speedKmh,
  }) {
    final remainM = math.max(0.0, _totalMeters - currentMeters);
    final remainKm = remainM / 1000.0;

    // 속도가 3km/h 이하로 거의 멈춘 경우 기본 정체 속도(15km/h)로 폴백 계산
    final effectiveSpeed = speedKmh >= 3.0 ? speedKmh : 15.0;
    final seconds = (remainKm / effectiveSpeed * 3600).round();

    return (
      remainingMeters: remainM,
      remainingKm: remainKm,
      estimatedSeconds: seconds,
      estimatedMinutes: (seconds / 60).ceil(),
    );
  }

  /// 실제 위·경도 궤적을 순회하며 코스의 곡률(진행 방위각 변화)로 턴 구간 감지
  List<RouteTurn> _findTurns() {
    final out = <RouteTurn>[];
    const distanceCalc = Distance();

    for (var i = 1; i < points.length - 1; i++) {
      final pPrev = points[i - 1];
      final pCurr = points[i];
      final pNext = points[i + 1];

      final bearing1 = distanceCalc.bearing(pPrev, pCurr);
      final bearing2 = distanceCalc.bearing(pCurr, pNext);

      var diff = bearing2 - bearing1;
      while (diff < -180) {
        diff += 360;
      }
      while (diff > 180) {
        diff -= 360;
      }

      if (diff.abs() < AppConfig.turnMinAngleDeg) continue;

      out.add(RouteTurn(
        distanceMeters: _cumulativeMeters[i],
        angleDeg: diff,
        kind: _classifyTurn(diff),
        position: pCurr,
      ));
    }
    return out;
  }

  static NavTurnKind _classifyTurn(double angle) {
    final a = angle.abs();
    if (a < 45) return angle > 0 ? NavTurnKind.slightRight : NavTurnKind.slightLeft;
    if (a < 120) return angle > 0 ? NavTurnKind.right : NavTurnKind.left;
    if (a < 150) return angle > 0 ? NavTurnKind.sharpRight : NavTurnKind.sharpLeft;
    return NavTurnKind.uTurn;
  }

  /// 현재 구동 위치(m) 이후의 다음 턴 안내
  ({RouteTurn? turn, double distanceToTurnMeters}) nextTurnAtDistance(double currentMeters) {
    if (_turns.isEmpty) return (turn: null, distanceToTurnMeters: 0);
    for (final t in _turns) {
      if (t.distanceMeters > currentMeters) {
        return (turn: t, distanceToTurnMeters: t.distanceMeters - currentMeters);
      }
    }
    return (turn: null, distanceToTurnMeters: 0);
  }
}

/// 현재 차량의 진행 방향 방위각(Bearing/Heading, Degree 0~360) 산출
double routeHeadingAtDistance(RouteGeometry r, double currentMeters) {
  const distanceCalc = Distance();
  final a = r.pointAtDistance(currentMeters);
  final b = r.pointAtDistance(math.min(r.totalMeters, currentMeters + 3.0)); // 3미터 앞 지점 참조
  return distanceCalc.bearing(a, b);
}