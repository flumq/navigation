import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

const double kEarthRadiusM = 6371000.0;
const double kLatMetersPerDeg = 110574.0;

/// 위·경도 두 지점 간의 실제 거리(미터) 계산 (latlong2 Distance 엔진 활용)
double haversineM(double la1, double lo1, double la2, double lo2) {
  const distanceCalc = Distance();
  return distanceCalc.as(
    LengthUnit.Meter,
    LatLng(la1, lo1),
    LatLng(la2, lo2),
  );
}

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 원형(0~1) 진행률 사이의 최단 거리 (0~0.5).
double circular01(double a, double b) {
  final d = (b - a).abs() % 1.0;
  return d > 0.5 ? 1.0 - d : d;
}

/// [from]에서 [to]까지 진행 방향으로 잰 진행률 차이 (0 이상 1 미만).
double forwardProgress(double from, double to) {
  final d = (to - from) % 1.0;
  return d < 0 ? d + 1.0 : d;
}

String two(int n) => n.toString().padLeft(2, '0');

String hms(DateTime t) => '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

String formatNavDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';