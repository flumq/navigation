import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import '../core/config.dart';
import '../core/geo.dart';

// 2026-11-02 현장 GPS 기록(127 fixes)을 기준으로 생성한 실제 순환 코스.
// 원본 기록을 지역 평면좌표(m)로 변환한 뒤 2.5m RDP 단순화 적용.
// 첫/마지막 점은 GPS 오차로 약 8m 차이가 나므로 동일 좌표로 닫아 순환 경로로 처리.
final RouteGeometry kCourseRoute = RouteGeometry(const [
  LatLng(37.2328522, 126.7788058),
  LatLng(37.2328921, 126.7788231),
  LatLng(37.2328435, 126.7789200),
  LatLng(37.2328202, 126.7796515),
  LatLng(37.2327869, 126.7797876),
  LatLng(37.2327475, 126.7798171),
  LatLng(37.2298318, 126.7796328),
  LatLng(37.2297061, 126.7796714),
  LatLng(37.2296540, 126.7798039),
  LatLng(37.2296102, 126.7807701),
  LatLng(37.2295140, 126.7809473),
  LatLng(37.2295259, 126.7810722),
  LatLng(37.2296286, 126.7811285),
  LatLng(37.2298096, 126.7810833),
  LatLng(37.2302752, 126.7812411),
  LatLng(37.2305272, 126.7812785),
  LatLng(37.2318780, 126.7810824),
  LatLng(37.2329028, 126.7809961),
  LatLng(37.2331565, 126.7809020),
  LatLng(37.2333707, 126.7807260),
  LatLng(37.2335719, 126.7803586),
  LatLng(37.2337271, 126.7797928),
  LatLng(37.2337333, 126.7793639),
  LatLng(37.2336073, 126.7789706),
  LatLng(37.2334656, 126.7787475),
  LatLng(37.2332919, 126.7785824),
  LatLng(37.2329868, 126.7784154),
  LatLng(37.2329011, 126.7784977),
  LatLng(37.2328522, 126.7788058),
]);

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

class RouteGeometry {
  RouteGeometry(this.points) {
    if (points.length < 2) {
      throw ArgumentError('코스 좌표는 2개 이상 필요합니다.');
    }
    _originLat = points.first.latitude;
    _originLon = points.first.longitude;
    _cosLat = math.cos(_originLat * math.pi / 180.0);

    for (final point in points) {
      _localPoints.add(_toLocal(point));
    }

    _cumulativeMeters.add(0.0);
    for (var i = 0; i < points.length - 1; i++) {
      final a = _localPoints[i];
      final b = _localPoints[i + 1];
      final len = (b - a).distance;
      _segmentLengthsMeters.add(len);
      _cumulativeMeters.add(_cumulativeMeters.last + len);
    }
    _totalMeters = _cumulativeMeters.last;
    _turns = _findTurns();
  }

  final List<LatLng> points;
  final List<Offset> _localPoints = [];
  final List<double> _segmentLengthsMeters = [];
  final List<double> _cumulativeMeters = [];
  late final double _originLat, _originLon, _cosLat;
  late final double _totalMeters;
  late final List<RouteTurn> _turns;

  double get totalMeters => _totalMeters;
  double get totalKm => _totalMeters / 1000.0;
  List<RouteTurn> get turns => List.unmodifiable(_turns);

  Offset _toLocal(LatLng p) => Offset(
        (p.longitude - _originLon) * 111320.0 * _cosLat,
        (p.latitude - _originLat) * 110574.0,
      );

  LatLng pointAtDistance(double meters) {
    final targetMeters = meters.clamp(0.0, _totalMeters).toDouble();
    for (var i = 0; i < _segmentLengthsMeters.length; i++) {
      if (targetMeters <= _cumulativeMeters[i + 1] ||
          i == _segmentLengthsMeters.length - 1) {
        final len = _segmentLengthsMeters[i];
        final t = len == 0
            ? 0.0
            : ((targetMeters - _cumulativeMeters[i]) / len).clamp(0.0, 1.0);
        final a = points[i];
        final b = points[i + 1];
        return LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
      }
    }
    return points.last;
  }

  LatLng pointAt(double progress) =>
      pointAtDistance(clamp01(progress) * _totalMeters);

  /// GPS 좌표를 각 선분에 미터 단위로 투영한다.
  /// hintDistanceMeters가 주어지면 현재 진행 위치 주변의 선분을 우선 탐색해
  /// 교차로나 서로 가까운 도로에서 다른 구간으로 순간 이동하는 현상을 줄인다.
  ({
    double distanceMeters,
    double offRouteDistanceMeters,
    LatLng closestPoint,
  }) projectLatLng(
    LatLng pos, {
    double? hintDistanceMeters,
    double searchWindowMeters = double.infinity,
  }) {
    final p = _toLocal(pos);
    var bestGlobalDistance = double.infinity;
    var bestGlobalAlong = 0.0;
    var bestGlobalPoint = points.first;
    var bestLocalDistance = double.infinity;
    var bestLocalAlong = 0.0;
    var bestLocalPoint = points.first;
    var foundLocal = false;

    for (var i = 0; i < _segmentLengthsMeters.length; i++) {
      final a = _localPoints[i];
      final b = _localPoints[i + 1];
      final v = b - a;
      final lenSq = v.dx * v.dx + v.dy * v.dy;
      if (lenSq <= 1e-9) continue;

      final t = (((p.dx - a.dx) * v.dx + (p.dy - a.dy) * v.dy) / lenSq)
          .clamp(0.0, 1.0)
          .toDouble();
      final q = Offset(a.dx + v.dx * t, a.dy + v.dy * t);
      final off = (p - q).distance;
      final along = _cumulativeMeters[i] + _segmentLengthsMeters[i] * t;
      final latLngA = points[i];
      final latLngB = points[i + 1];
      final projected = LatLng(
        latLngA.latitude + (latLngB.latitude - latLngA.latitude) * t,
        latLngA.longitude + (latLngB.longitude - latLngA.longitude) * t,
      );

      if (off < bestGlobalDistance) {
        bestGlobalDistance = off;
        bestGlobalAlong = along;
        bestGlobalPoint = projected;
      }

      if (hintDistanceMeters != null) {
        final delta = (along - hintDistanceMeters).abs();
        final circularDelta = math.min(delta, _totalMeters - delta);
        if (circularDelta > searchWindowMeters) continue;
      }
      foundLocal = true;
      if (off < bestLocalDistance) {
        bestLocalDistance = off;
        bestLocalAlong = along;
        bestLocalPoint = projected;
      }
    }

    if (foundLocal) {
      return (
        distanceMeters: bestLocalAlong,
        offRouteDistanceMeters: bestLocalDistance,
        closestPoint: bestLocalPoint,
      );
    }
    return (
      distanceMeters: bestGlobalAlong,
      offRouteDistanceMeters: bestGlobalDistance,
      closestPoint: bestGlobalPoint,
    );
  }

  ({
    double remainingMeters,
    double remainingKm,
    int estimatedSeconds,
    int estimatedMinutes,
  }) calculateETA({
    required double currentMeters,
    required double speedKmh,
  }) {
    final remainM = math.max(0.0, _totalMeters - currentMeters);
    final remainKm = remainM / 1000.0;
    final effectiveSpeed = speedKmh >= 3.0 ? speedKmh : 15.0;
    final seconds = (remainKm / effectiveSpeed * 3600).round();
    return (
      remainingMeters: remainM,
      remainingKm: remainKm,
      estimatedSeconds: seconds,
      estimatedMinutes: (seconds / 60).ceil(),
    );
  }

  List<RouteTurn> _findTurns() {
    final out = <RouteTurn>[];
    const distanceCalc = Distance();
    for (var i = 1; i < points.length - 1; i++) {
      final bearing1 = distanceCalc.bearing(points[i - 1], points[i]);
      final bearing2 = distanceCalc.bearing(points[i], points[i + 1]);
      var diff = bearing2 - bearing1;
      while (diff < -180) { diff += 360; }
      while (diff > 180) { diff -= 360; }
      if (diff.abs() < AppConfig.turnMinAngleDeg) continue;
      out.add(RouteTurn(
        distanceMeters: _cumulativeMeters[i],
        angleDeg: diff,
        kind: _classifyTurn(diff),
        position: points[i],
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

  ({RouteTurn? turn, double distanceToTurnMeters}) nextTurnAtDistance(
    double currentMeters,
  ) {
    for (final t in _turns) {
      if (t.distanceMeters > currentMeters) {
        return (turn: t, distanceToTurnMeters: t.distanceMeters - currentMeters);
      }
    }
    return (turn: null, distanceToTurnMeters: 0);
  }
}

double routeHeadingAtDistance(RouteGeometry r, double currentMeters) {
  const distanceCalc = Distance();
  final a = r.pointAtDistance(currentMeters);
  final target = r.totalMeters <= 0 ? 0.0 : (currentMeters + 3.0) % r.totalMeters;
  final b = r.pointAtDistance(target);
  return distanceCalc.bearing(a, b);
}
