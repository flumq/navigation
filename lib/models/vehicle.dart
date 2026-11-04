import 'package:latlong2/latlong.dart';

import '../core/config.dart';

enum VehicleType { taxi, bus }

/// 서버로 전송하는 GPS 이력의 최소 단위.
class TrailPoint {
  const TrailPoint({required this.lat, required this.lon, required this.ms});

  final double lat, lon;
  final int ms;

  /// 압축 포맷 [lat, lon, ms]. 서버 용량을 아끼기 위해 키 이름을 넣지 않는다.
  List<dynamic> toJson() => [lat, lon, ms];

  factory TrailPoint.fromJson(List e) => TrailPoint(
        lat: (e[0] as num).toDouble(),
        lon: (e[1] as num).toDouble(),
        ms: (e[2] as num).toInt(),
      );
}

class VehicleState {
  const VehicleState({
    required this.id,
    required this.type,
    required this.progress,
    required this.speedKmh,
    required this.position,
    required this.deviation,
    required this.isOffRoute,
    required this.location,
    required this.status,
    this.avgSpeedKmh = 0,
    this.laps = 0,
    this.trail = const <TrailPoint>[],
  });

  final String id;
  final VehicleType type;
  final double progress, speedKmh, deviation;

  /// 💡 기존 가상 픽셀 Offset 대신 실제 지도 위·경도(LatLng) 좌표를 사용합니다.
  final LatLng position;
  final bool isOffRoute;
  final String location, status;

  /// 최근 [AppConfig.avgSpeedWindowSec]초 평균 속도(km/h).
  final double avgSpeedKmh;

  /// 순환 코스 완주 횟수.
  final int laps;

  /// 최근 주행 궤적. 상태 노드에는 포함되지 않고 별도 노드에서 받는다.
  final List<TrailPoint> trail;

  VehicleState withTrail(List<TrailPoint> t) => VehicleState(
        id: id,
        type: type,
        progress: progress,
        speedKmh: speedKmh,
        position: position,
        deviation: deviation,
        isOffRoute: isOffRoute,
        location: location,
        status: status,
        avgSpeedKmh: avgSpeedKmh,
        laps: laps,
        trail: t,
      );
}
