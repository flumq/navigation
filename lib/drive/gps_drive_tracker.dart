import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:geolocator/geolocator.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import '../services/calibration_service.dart';
import 'telemetry.dart';

/// 실제 GPS fix를 받아 코스 위의 진행률, 이탈, 주행 기록을 계산한다.
class GpsDriveTracker {
  GpsDriveTracker(
    this.route, {
    this.type = VehicleType.taxi,
    void Function(int laps)? onLap,
  }) : telemetry = DriveTelemetry(onLap: onLap);

  final RouteGeometry route;
  final VehicleType type;
  final DriveTelemetry telemetry;

  Offset? _mapPos;
  DateTime? _lastFixTime;
  DateTime? _lastFixWall;
  DateTime? _offWindowSince;
  double _lastDt = 1.0;

  double? progress;
  double distance = 0;
  double speedKmh = 0;
  double accuracyM = 0;

  bool get hasFix => _mapPos != null;
  Offset? get position => _mapPos;
  bool get isOffRoute => telemetry.offRoute.isOff;
  double get avgSpeedKmh => telemetry.avgSpeedKmh;
  int get laps => telemetry.laps;
  List<TrailPoint> get trail => telemetry.trail;

  bool get isStale =>
      _lastFixWall == null ||
      DateTime.now().difference(_lastFixWall!).inSeconds > 5;

  void onFix(Position p) {
    if (p.accuracy > AppConfig.gpsAccuracyLimitM) return;

    final raw = gpsToMap(p.latitude, p.longitude);
    final prev = _mapPos;
    final pos =
        prev == null ? raw : Offset.lerp(prev, raw, AppConfig.gpsSmoothing)!;

    var dt = 1.0;
    if (_lastFixTime != null) {
      dt = (p.timestamp.difference(_lastFixTime!).inMilliseconds / 1000)
          .clamp(0.1, 5.0)
          .toDouble();
    }
    _lastDt = dt;
    _lastFixTime = p.timestamp;
    _lastFixWall = DateTime.now();
    _mapPos = pos;
    accuracyM = p.accuracy;
    speedKmh = (p.speed.isFinite && p.speed > 0 ? p.speed : 0) * 3.6;

    _updateProgress(pos, p.accuracy, _lastDt);

    telemetry.offRoute.update(
      distanceM: distance,
      thresholdM: AppConfig.gpsOffRouteThresholdM,
      dtSec: _lastDt,
    );

    final current = progress;
    if (current != null) {
      telemetry.record(
        progress: current,
        speedKmh: speedKmh,
        lat: p.latitude,
        lon: p.longitude,
      );
    }
  }

  /// 이전 진행률 근처에서만 찾고, 그 창을 벗어나도 일정 시간이 지나면 전역 탐색으로 복구한다.
  void _updateProgress(Offset pos, double accuracy, double dt) {
    final global = route.project(pos);
    final current = progress;

    if (current == null) {
      progress = global.progress;
      distance = global.distance;
      _offWindowSince = null;
      return;
    }

    final windowM = math.max(
      15.0,
      (speedKmh / 3.6) * dt * 2.5 + accuracy + 8,
    );
    final local = route.projectNear(pos, current, windowM);
    if (local != null) {
      progress = local.progress;
      distance = local.distance;
      _offWindowSince = null;
      return;
    }

    distance = global.distance;
    _offWindowSince ??= DateTime.now();
    final lost = DateTime.now().difference(_offWindowSince!).inSeconds;
    if (lost >= 4 && global.distance <= AppConfig.gpsOffRouteThresholdM + 8) {
      progress = global.progress;
      distance = global.distance;
      _offWindowSince = null;
    }
  }

  VehicleState toState({required String id, required String location}) =>
      VehicleState(
        id: id,
        type: type,
        progress: progress ?? 0,
        speedKmh: speedKmh,
        avgSpeedKmh: telemetry.avgSpeedKmh,
        laps: telemetry.laps,
        trail: telemetry.trail,
        position: _mapPos ?? Offset.zero,
        deviation: distance,
        isOffRoute: isOffRoute,
        location: location,
        status: isOffRoute ? '경로 이탈!' : '정상 주행',
      );
}