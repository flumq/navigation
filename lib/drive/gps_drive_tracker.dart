import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import 'telemetry.dart';

/// 실제 GPS fix를 코스 위 진행률·이탈·주행 기록으로 변환한다.
class GpsDriveTracker {
  GpsDriveTracker(
    this.route, {
    this.type = VehicleType.taxi,
    void Function(int laps)? onLap,
  }) : telemetry = DriveTelemetry(onLap: onLap);

  final RouteGeometry route;
  final VehicleType type;
  final DriveTelemetry telemetry;

  LatLng? _currentLatLng;
  DateTime? _lastFixTime;
  DateTime? _lastFixWall;
  DateTime? _offWindowSince;

  double? progress;
  double currentDistanceMeters = 0;
  double deviationMeters = 0;
  double speedKmh = 0;
  double accuracyM = 0;

  bool get hasFix => _currentLatLng != null;
  LatLng? get position => _currentLatLng;
  bool get isOffRoute => telemetry.offRoute.isOff;
  double get avgSpeedKmh => telemetry.avgSpeedKmh;
  int get laps => telemetry.laps;
  List<TrailPoint> get trail => telemetry.trail;

  bool get isStale =>
      _lastFixWall == null ||
      DateTime.now().difference(_lastFixWall!).inSeconds > 5;

  void onFix(Position p) {
    if (!p.latitude.isFinite ||
        !p.longitude.isFinite ||
        p.accuracy.isNaN ||
        p.accuracy > AppConfig.gpsAccuracyLimitM) {
      return;
    }

    var dt = 1.0;
    if (_lastFixTime != null) {
      final elapsed =
          p.timestamp.difference(_lastFixTime!).inMilliseconds / 1000.0;
      if (elapsed <= 0) return;
      dt = elapsed.clamp(0.1, 5.0).toDouble();
    }
    _lastFixTime = p.timestamp;
    _lastFixWall = DateTime.now();
    accuracyM = p.accuracy;
    speedKmh = (p.speed.isFinite && p.speed > 0 ? p.speed : 0) * 3.6;

    final raw = LatLng(p.latitude, p.longitude);
    final prev = _currentLatLng;
    final alpha = (AppConfig.gpsSmoothing -
            (p.accuracy > 10 ? 0.15 : 0.0))
        .clamp(0.55, 0.95)
        .toDouble();
    final pos = prev == null
        ? raw
        : LatLng(
            prev.latitude + (raw.latitude - prev.latitude) * alpha,
            prev.longitude + (raw.longitude - prev.longitude) * alpha,
          );
    _currentLatLng = pos;

    _updateProgress(pos, p.accuracy, dt);

    telemetry.offRoute.update(
      distanceM: deviationMeters,
      thresholdM: AppConfig.gpsOffRouteThresholdM,
      dtSec: dt,
    );

    final currentProg = progress;
    if (currentProg != null) {
      // 실제 GPS 좌표를 기록한다. 화면 마커용 스무딩 좌표와 분리한다.
      telemetry.record(
        progress: currentProg,
        speedKmh: speedKmh,
        lat: p.latitude,
        lon: p.longitude,
      );
    }
  }

  void _updateProgress(LatLng pos, double accuracy, double dt) {
    final currentProg = progress;
    if (currentProg == null) {
      final first = route.projectLatLng(pos);
      currentDistanceMeters = first.distanceMeters;
      progress = currentDistanceMeters / route.totalMeters;
      deviationMeters = first.offRouteDistanceMeters;
      return;
    }

    final currentMeters = currentProg * route.totalMeters;
    final expectedTravel = (speedKmh / 3.6) * dt;
    final searchWindow = math.max(
      45.0,
      expectedTravel * 5 + accuracy * 3 + 25,
    );

    final projected = route.projectLatLng(
      pos,
      hintDistanceMeters: currentMeters,
      searchWindowMeters: searchWindow,
    );

    final candidate = projected.distanceMeters;
    final signedDelta = candidate - currentMeters;
    final plausibleForward = signedDelta >= -math.max(12.0, accuracy * 2) &&
        signedDelta <= searchWindow;
    final nearStartWrap = currentMeters > route.totalMeters * 0.85 &&
        candidate < route.totalMeters * 0.15;

    deviationMeters = projected.offRouteDistanceMeters;

    if (plausibleForward || nearStartWrap) {
      currentDistanceMeters = candidate;
      progress = (candidate / route.totalMeters).clamp(0.0, 1.0);
      _offWindowSince = null;
      return;
    }

    // 현재 진행 구간 근처에서 찾은 위치가 지나치게 멀면 GPS 이탈로 취급한다.
    // 일정 시간 이상 같은 방향으로 이탈한 경우에만 새 위치로 재동기화한다.
    _offWindowSince ??= DateTime.now();
    final lost = DateTime.now().difference(_offWindowSince!).inSeconds;
    if (lost >= 4 && deviationMeters <= AppConfig.gpsOffRouteThresholdM + 8) {
      currentDistanceMeters = candidate;
      progress = (candidate / route.totalMeters).clamp(0.0, 1.0);
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
        position: _currentLatLng ?? route.points.first,
        deviation: deviationMeters,
        isOffRoute: isOffRoute,
        location: location,
        status: isOffRoute ? '경로 이탈!' : '정상 주행',
      );

  double get speedKsmhSafe => speedKmh;
}
