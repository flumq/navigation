
import 'package:flutter/material.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../models/pickup.dart';
import '../models/vehicle.dart';
import 'map_layers.dart';

// =============================================================================
// 1. 스타일
// =============================================================================
class NavStyle {
  NavStyle._();

  static const double scale = 1.6;
  static const double lookAhead = 0.22;
  static const double vehicleYRatio = 0.62;
  static const Color bg = Color(0xFFFFFFFF);
  static const Color routeAhead = Color(0xFF1E88E5);
  static const Color routeBehind = Color(0x661E88E5);
  static const Color navy = Color(0xFF1B2631);
}

// =============================================================================
// 2. 경로 샘플 (캐시)
// =============================================================================

/// 진행률 [from]에서 [length] 구간을 샘플링한다. 순환 코스이므로 1.0을 넘으면 감싼다.
List<Offset> routeSamples(RouteGeometry r, double from, double length) {
  final n = (length * 500).round().clamp(2, 100000);
  return [
    for (var i = 0; i <= n; i++) r.pointAt((from + length * i / n) % 1.0),
  ];
}

/// 전체 코스는 변하지 않으므로 한 번만 계산한다.
final List<Offset> _kFullRouteSamples = routeSamples(kCourseRoute, 0, 1);

// =============================================================================
// 3. 오버레이 페인터
// =============================================================================
class NavOverlayPainter extends CustomPainter {
  NavOverlayPainter({
    required this.progress,
    required this.route,
    required this.others,
    this.pickups = const [],
  });

  final double progress;
  final RouteGeometry route;
  final List<VehicleState> others;
  final List<PickupPoint> pickups;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;

    // 지나온 길 (캐시된 전체 샘플 사용)
    canvas.drawPath(
      routePath(_kFullRouteSamples, size),
      Paint()
        ..color = NavStyle.routeBehind
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 앞쪽 안내 구간 (진행률에 따라 달라지므로 매번 계산)
    final ahead = routePath(
      routeSamples(route, progress, NavStyle.lookAhead),
      size,
    );
    canvas.drawPath(
      ahead,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 14
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      ahead,
      Paint()
        ..color = NavStyle.routeAhead
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 승차/하차 지점
    for (final p in pickups) {
      final pos = Offset(p.mapPosition.dx * w, p.mapPosition.dy * h);
      canvas.drawCircle(pos, 10, Paint()..color = Colors.white);
      canvas.drawCircle(pos, 7, Paint()..color = pickupColor(p.kind));
      canvas.drawCircle(pos, 3, Paint()..color = Colors.white);
    }

    // 다른 차량
    for (final v in others) {
      final p = Offset(v.position.dx * w, v.position.dy * h);
      canvas.drawCircle(p, 9, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        6.5,
        Paint()
          ..color = v.type == VehicleType.taxi ? AppColors.taxi : AppColors.bus,
      );
    }
  }

  @override
  bool shouldRepaint(covariant NavOverlayPainter old) =>
      old.progress != progress ||
      !identical(old.pickups, pickups) ||
      !_sameOthers(old.others, others);
}

/// 다른 차량 목록이 실제로 바뀌었는지 비교한다.
/// 리스트 객체가 매번 새로 만들어지므로 identical만으로는 부족하다.
bool _sameOthers(List<VehicleState> a, List<VehicleState> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].position != b[i].position || a[i].type != b[i].type) return false;
  }
  return true;
}