import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import 'telemetry.dart';

/// 실제 GPS fix를 받아 코스 위의 진행률, 이탈, 주행 기록을 실제 위·경도(LatLng) 기반으로 계산한다.
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
  double _lastDt = 1.0;

  double? progress;
  double currentDistanceMeters = 0; // 누적 미터 거리
  double deviationMeters = 0;       // 코스 이격 거리 (m)
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
    if (p.accuracy > AppConfig.gpsAccuracyLimitM) return;

    final rawLatLng = LatLng(p.latitude, p.longitude);
    final prev = _currentLatLng;
    
    // GPS 위치 부드러운 보간 (간이 스무딩)
    final LatLng pos;
    if (prev == null) {
      pos = rawLatLng;
    } else {
      final lat = prev.latitude + (rawLatLng.latitude - prev.latitude) * AppConfig.gpsSmoothing;
      final lon = prev.longitude + (rawLatLng.longitude - prev.longitude) * AppConfig.gpsSmoothing;
      pos = LatLng(lat, lon);
    }

    var dt = 1.0;
    if (_lastFixTime != null) {
      dt = (p.timestamp.difference(_lastFixTime!).inMilliseconds / 1000)
          .clamp(0.1, 5.0)
          .toDouble();
    }
    _lastDt = dt;
    _lastFixTime = p.timestamp;
    _lastFixWall = DateTime.now();
    _currentLatLng = pos;
    accuracyM = p.accuracy;
    speedKmh = (p.speed.isFinite && p.speed > 0 ? p.speed : 0) * 3.6;

    _updateProgress(pos, p.accuracy, _lastDt);

    telemetry.offRoute.update(
      distanceM: deviationMeters,
      thresholdM: AppConfig.gpsOffRouteThresholdM,
      dtSec: _lastDt,
    );

    final currentProg = progress;
    if (currentProg != null) {
      telemetry.record(
        progress: currentProg,
        speedKmh: speedKmh,
        lat: p.latitude,
        lon: p.longitude,
      );
    }
  }

  /// 위·경도 코스 엔진(`projectLatLng`)을 활용하여 현재 진행률과 이격 거리를 정밀 산출
  void _updateProgress(LatLng pos, double accuracy, double dt) {
    final global = route.projectLatLng(pos);
    final currentProg = progress;

    if (currentProg == null) {
      currentDistanceMeters = global.distanceMeters;
      progress = currentDistanceMeters / route.totalMeters;
      deviationMeters = global.offRouteDistanceMeters;
      _offWindowSince = null;
      return;
    }

    // 허용 윈도우 범위 계산 (미터 단위)
    final windowM = math.max(
      15.0,
      (speedKmh / 3.6) * dt * 2.5 + accuracy + 8,
    );

    // 전역 투영 위치가 현재 진행 위치와 가까운지 검증
    final globalMeters = global.distanceMeters;
    final currentMeters = currentProg * route.totalMeters;
    final diffM = (globalMeters - currentMeters).abs();

    if (diffM <= windowM || diffM >= route.totalMeters - windowM) {
      currentDistanceMeters = globalMeters;
      progress = (currentDistanceMeters / route.totalMeters).clamp(0.0, 1.0);
      deviationMeters = global.offRouteDistanceMeters;
      _offWindowSince = null;
      return;
    }

    deviationMeters = global.offRouteDistanceMeters;
    _offWindowSince ??= DateTime.now();
    final lost = DateTime.now().difference(_offWindowSince!).inSeconds;
    if (lost >= 4 && deviationMeters <= AppConfig.gpsOffRouteThresholdM + 8) {
      currentDistanceMeters = globalMeters;
      progress = (currentDistanceMeters / route.totalMeters).clamp(0.0, 1.0);
      _offWindowSince = null;
    }
  }

  VehicleState toState({required String id, required String location}) =>
      VehicleState(
        id: id,
        type: type,
        progress: progress ?? 0,
        speedKmh: speedKmh, // 💡 괄호나 함수 호출 형식이 아닌 속성값 그대로 전달
        avgSpeedKmh: telemetry.avgSpeedKmh,
        laps: telemetry.laps,
        trail: telemetry.trail,
        position: _currentLatLng ?? const LatLng(37.2315, 126.7795),
        deviation: deviationMeters,
        isOffRoute: isOffRoute,
        location: location,
        status: isOffRoute ? '경로 이탈!' : '정상 주행',
      );
          
  double get speedKsmhSafe => speedKmh;
}