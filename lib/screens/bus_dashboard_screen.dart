import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../core/config.dart';
import '../core/geo.dart';
import '../drive/gps_drive_tracker.dart';
import '../drive/simulator.dart';
import '../drive/telemetry.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import '../services/fleet_repository.dart';
import '../services/gps_service.dart';
import '../widgets/common.dart';

class BusDashboardScreen extends StatefulWidget {
  const BusDashboardScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<BusDashboardScreen> createState() => _BusDashboardScreenState();
}

class _BusDashboardScreenState extends State<BusDashboardScreen> {
  final FleetRepository _fleet = FleetHub.current;
  late final VehicleSimulator _sim;
  late final GpsDriveTracker _gps;
  StreamSubscription<Position>? _gpsSub;
  Timer? _timer;
  int _tickCount = 0;
  String _clock = '';
  bool _simMode = false;
  String _gpsStatus = 'GPS 연결 중…';

  @override
  void initState() {
    super.initState();
    _sim = VehicleSimulator(
      id: widget.driverId,
      type: VehicleType.bus,
      route: kCourseRoute,
    )..speedKmh = AppConfig.busCruiseKmh;
    _gps = GpsDriveTracker(kCourseRoute, type: VehicleType.bus);
    _startGps();
    _timer = Timer.periodic(
      const Duration(milliseconds: AppConfig.tickMs),
      (_) => _tick(),
    );
  }

  Future<void> _startGps() async {
    final error = await ensureGpsReady();
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _simMode = true;
        _gpsStatus = '$error · 시뮬레이션';
      });
      return;
    }
    _gpsSub = gpsStream().listen(
      (p) {
        _gps.onFix(p);
        if (mounted) {
          setState(() =>
              _gpsStatus = 'GPS 정확도 ${p.accuracy.toStringAsFixed(0)} m');
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => _gpsStatus = 'GPS 오류: $e');
      },
    );
  }

  double get _progress => _simMode ? _sim.progress : (_gps.progress ?? 0);
  double get _speed => _simMode ? _sim.speedKmh : _gps.speedKmh;
  bool get _offRoute => _simMode ? _sim.isOffRoute : _gps.isOffRoute;
  double get _myAvgSpeed =>
      _simMode ? _sim.telemetry.avgSpeedKmh : _gps.avgSpeedKmh;
  int get _laps => _simMode ? _sim.telemetry.laps : _gps.laps;

  void _tick() {
    if (!mounted) return;
    if (_simMode) {
      _sim.step(AppConfig.tickMs / 1000);
      _fleet.publish(_sim.toState(location: '시뮬레이션 주행'));
    } else if (_gps.hasFix) {
      _fleet.publish(_gps.toState(
        id: widget.driverId,
        location: _gps.isStale ? 'GPS 신호 약함' : '순환 코스 주행 중',
      ));
    }

    // 궤적은 상태보다 느리게(기본 10초) 따로 올린다.
    _tickCount++;
    final every = AppConfig.trailUploadSec * 1000 ~/ AppConfig.tickMs;
    if (_tickCount % every == 0) {
      final trail = _simMode ? _sim.telemetry.trail : _gps.trail;
      _fleet.publishTrail(widget.driverId, trail);
    }

    setState(() => _clock = hms(DateTime.now()));
  }

  ({double? frontKm, double? rearKm, double frontSpeed, double rearSpeed})
      _headway() {
    double? frontKm, rearKm;
    double frontSpeed = 0, rearSpeed = 0;
    for (final v in _fleet.vehicles) {
      if (v.type != VehicleType.bus || v.id == widget.driverId) continue;
      final fwd = forwardProgress(_progress, v.progress);
      final kmh = headwaySpeedKmh(
        avgA: _myAvgSpeed,
        avgB: v.avgSpeedKmh,
        instA: _speed,
        instB: v.speedKmh,
      );

      if (fwd < 0.5) {
        if (frontKm == null || fwd < frontKm) {
          frontKm = fwd;
          frontSpeed = kmh;
        }
      } else {
        final bwd = 1 - fwd;
        if (rearKm == null || bwd < rearKm) {
          rearKm = bwd;
          rearSpeed = kmh;
        }
      }
    }
    return (
      frontKm: frontKm == null ? null : frontKm * AppConfig.routeLengthKm,
      rearKm: rearKm == null ? null : rearKm * AppConfig.routeLengthKm,
      frontSpeed: frontSpeed,
      rearSpeed: rearSpeed,
    );
  }

  String _timeText(double km, double kmh) {
    if (kmh < 3) return '속도 정보 없음';
    final sec = (km / kmh * 3600).round();
    return '${sec ~/ 60}분 ${sec % 60}초 차이 '
        '(평균 ${kmh.toStringAsFixed(1)} km/h)';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _gpsSub?.cancel();
    _fleet.remove(widget.driverId);
    super.dispose();
  }

  Widget _gapCard(String title, Color color, double? km, double kmh) => AppCard(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Center(
              child: Text(
                km == null ? '차량 없음' : '${km.toStringAsFixed(2)} km',
                style: const TextStyle(
                  color: AppColors.dark,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                km == null ? '-' : _timeText(km, kmh),
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
            const Spacer(),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _fleet,
        builder: (context, _) {
          final gap = _headway();
          return Scaffold(
            appBar: AppBar(
              title: Text('버스 배차 간격 관제 · ${widget.driverId}'),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.dark,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Flexible(
                        child: Text(
                          'T머니 교통카드시스템 (BMS)',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        _clock,
                        style: const TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Icon(
                        _simMode ? Icons.gps_off : Icons.gps_fixed,
                        color: _simMode ? Colors.orangeAccent : Colors.greenAccent,
                        size: 16,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(children: [
                    Expanded(
                      flex: 4,
                      child: _gapCard(
                        '앞차 간격',
                        AppColors.bus,
                        gap.frontKm,
                        gap.frontSpeed,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: GradientCard(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.directions_bus,
                              color: Colors.white,
                              size: 44,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              '내 버스 차량',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.driverId,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.yellowAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${_speed.toStringAsFixed(0)} km/h',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '평균 ${_myAvgSpeed.toStringAsFixed(1)} km/h · $_laps랩',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _gpsStatus,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            if (_offRoute) ...[
                              const SizedBox(height: 6),
                              const Text(
                                '경로 이탈',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: _gapCard(
                        '뒤차 간격',
                        AppColors.accent,
                        gap.rearKm,
                        gap.rearSpeed,
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
}