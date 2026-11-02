import 'dart:ui' show Offset;

import '../core/config.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import '../services/calibration_service.dart';
import 'telemetry.dart';

/// 실제 GPS가 없을 때 쓰는 가상 차량.
class VehicleSimulator {
  VehicleSimulator({
    required this.id,
    required this.type,
    required this.route,
    this.progress = 0,
    void Function(int laps)? onLap,
  }) : telemetry = DriveTelemetry(onLap: onLap);

  final String id;
  final VehicleType type;
  final RouteGeometry route;
  final DriveTelemetry telemetry;

  double progress;
  double speedKmh = 0;
  double lateral = 0;
  Offset position = Offset.zero;
  double deviation = 0;
  bool isOffRoute = false;

  void accelerate(double delta) => speedKmh =
      (speedKmh + delta).clamp(0.0, AppConfig.maxSpeedKmh).toDouble();

  void steer(double delta) => lateral =
      (lateral + delta).clamp(-AppConfig.maxSteer, AppConfig.maxSteer).toDouble();

  void step(double dt) {
    progress =
        (progress + (speedKmh / 3600) * dt / AppConfig.routeLengthKm) % 1.0;
    position = route.positionWithOffset(progress, lateral);
    deviation = route.distanceTo(position);
    isOffRoute = telemetry.offRoute.update(
      distanceM: deviation,
      thresholdM: AppConfig.offRouteThresholdM,
      dtSec: dt,
    );
    final g = mapToGps(position);
    telemetry.record(
      progress: progress,
      speedKmh: speedKmh,
      lat: g.$1,
      lon: g.$2,
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