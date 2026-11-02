import 'dart:math' as math;

const double kEarthRadiusM = 6371000.0;

/// 위도 1도당 미터. 기본 투영 상수(kUE 등)가 이 값 기준으로 맞춰져 있으므로
/// 코드 전체에서 이 상수 하나만 사용한다. (기존에는 110540과 110574가 섞여 있었음)
const double kLatMetersPerDeg = 110574.0;

double metersPerDegLon(double lat) => 111320.0 * math.cos(lat * math.pi / 180);

double haversineM(double la1, double lo1, double la2, double lo2) {
  final p1 = la1 * math.pi / 180;
  final p2 = la2 * math.pi / 180;
  final dp = (la2 - la1) * math.pi / 180;
  final dl = (lo2 - lo1) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * kEarthRadiusM * math.asin(math.sqrt(h));
}

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 원형(0~1) 진행률 사이의 최단 거리 (0~0.5).
double circular01(double a, double b) {
  final d = (b - a).abs() % 1.0;
  return d > 0.5 ? 1.0 - d : d;
}

/// [from]에서 [to]까지 진행 방향으로 잰 진행률 차이 (0 이상 1 미만).
/// 기존에 3곳(_forward, _forwardGapKm, BusDashboardScreen._forward)에
/// 중복되어 있던 로직이다.
double forwardProgress(double from, double to) {
  final d = (to - from) % 1.0;
  return d < 0 ? d + 1.0 : d;
}

String two(int n) => n.toString().padLeft(2, '0');

String hms(DateTime t) => '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

String formatNavDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';