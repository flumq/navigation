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

  // GPS 원본 좌표와 화면 표시용 스무딩 좌표, 코스 투영 좌표를 분리한다.
  LatLng? _rawLatLng;
  LatLng? _currentLatLng;
  LatLng? _projectedLatLng;

  DateTime? _lastFixTime;
  DateTime? _lastFixWall;
  DateTime? _offWindowSince;

  double? progress;
  double currentDistanceMeters = 0;
  double deviationMeters = 0;
  double rawToRouteDistanceMeters = 0;
  double speedKmh = 0;
  double accuracyM = 0;

  /// 유효성 검사를 통과한 가장 최근의 GPS 원본 좌표.
  LatLng? get rawPosition => _rawLatLng;

  /// 기존 화면 호환성을 유지하는 GPS 스무딩 좌표.
  /// 기존 position getter의 의미는 변경하지 않는다.
  LatLng? get position => _currentLatLng;

  /// 진행률 계산에 사용된 코스 위 투영 좌표.
  LatLng? get projectedPosition => _projectedLatLng;

  /// GPS 원본 좌표와 투영 좌표 사이의 거리.
  double get gpsToRouteDistanceMeters => rawToRouteDistanceMeters;

  bool get hasFix => _currentLatLng != null;
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
        !p.accuracy.isFinite ||
        p.accuracy < 0 ||
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

    // 원본 GPS 좌표는 변형하지 않고 별도로 보관한다.
    final raw = LatLng(p.latitude, p.longitude);
    _rawLatLng = raw;

    // 화면 마커와 진행률 계산에는 기존 스무딩 방식을 유지한다.
    final prev = _currentLatLng;
    final alpha = (AppConfig.gpsSmoothing - (p.accuracy > 10 ? 0.15 : 0.0))
        .clamp(0.55, 0.95)
        .toDouble();

    final smoothed = prev == null
        ? raw
        : LatLng(
            prev.latitude + (raw.latitude - prev.latitude) * alpha,
            prev.longitude + (raw.longitude - prev.longitude) * alpha,
          );

    _currentLatLng = smoothed;

    _updateProgress(smoothed, p.accuracy, dt);

    // 원본 GPS와 코스 투영점의 차이를 별도로 기록한다.
    // 이 값은 지도 정합 상태를 확인하기 위한 진단값이다.
    final projected = _projectedLatLng;
    rawToRouteDistanceMeters = projected == null
        ? 0
        : const Distance().as(LengthUnit.Meter, raw, projected);

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
        lat: raw.latitude,
        lon: raw.longitude,
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
      _projectedLatLng = first.closestPoint;
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
    _projectedLatLng = projected.closestPoint;

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

    if (lost >= 4 &&
        deviationMeters <= AppConfig.gpsOffRouteThresholdM + 8) {
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
