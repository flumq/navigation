import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import 'telemetry.dart';

/// 실제 GPS가 없을 때 쓰는 가상 차량 시뮬레이터 (위·경도 기반)
class VehicleSimulator {
  VehicleSimulator({
    required this.id,
    required this.type,
    required this.route,
    this.progress = 0,
    void Function(int laps)? onLap,
  }) : telemetry = DriveTelemetry(onLap: onLap) {
    // 초기 위치 설정
    position = route.pointAt(progress);
  }

  final String id;
  final VehicleType type;
  final RouteGeometry route;
  final DriveTelemetry telemetry;

  double progress;
  double speedKmh = 0;
  double lateral = 0; // 측면 오프셋 (미터 단위)
  
  /// 💡 기존 Offset 대신 실제 지도 위·경도(LatLng) 좌표 사용
  LatLng position = const LatLng(37.2315, 126.7795);
  double deviation = 0;
  bool isOffRoute = false;

  void accelerate(double delta) => speedKmh =
      (speedKmh + delta).clamp(0.0, AppConfig.maxSpeedKmh).toDouble();

  void steer(double delta) => lateral =
      (lateral + delta).clamp(-AppConfig.maxSteer, AppConfig.maxSteer).toDouble();

  void step(double dt) {
    // 코스 전체 길이(m) 기준 진행률 업데이트
    final totalMeters = route.totalMeters;
    if (totalMeters > 0) {
      final movedMeters = (speedKmh / 3.6) * dt;
      final currentMeters = progress * totalMeters;
      progress = ((currentMeters + movedMeters) % totalMeters) / totalMeters;
    }

    // 💡 실제 코스 상의 위·경도 위치 산출
    position = route.pointAt(progress);
    
    // 코스 이격 거리 측정 (시뮬레이터이므로 기본 0 또는 lateral 반영)
    deviation = lateral.abs();
    
    isOffRoute = telemetry.offRoute.update(
      distanceM: deviation,
      thresholdM: AppConfig.gpsOffRouteThresholdM,
      dtSec: dt,
    );

    telemetry.record(
      progress: progress,
      speedKmh: speedKmh,
      lat: position.latitude,
      lon: position.longitude,
    );
  }

  VehicleState toState({required String location}) => VehicleState(
        id: id,
        type: type,
        progress: progress,
        speedKmh: speedKmh,
        avgSpeedKmh: telemetry.avgSpeedKmh,
        laps: telemetry.laps,
        trail: telemetry.trail,
        position: position,
        deviation: deviation,
        isOffRoute: isOffRoute,
        location: location,
        status: isOffRoute ? '경로 이탈!' : '정상 주행',
      );
}