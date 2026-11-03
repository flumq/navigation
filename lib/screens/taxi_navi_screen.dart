import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../core/geo.dart';
import '../drive/gps_drive_tracker.dart';
import '../drive/simulator.dart';
import '../models/course.dart';
import '../models/pickup.dart';
import '../models/vehicle.dart';
import '../services/fleet_repository.dart';
import '../services/gps_service.dart';
import '../services/pickup_store.dart';
import '../services/voice_announcer.dart';
import '../widgets/common.dart';

// =============================================================================
// 1. 승객 호출 상태
// =============================================================================
class PassengerCall {
  PassengerCall({
    required this.pickup,
    required this.distanceKm,
    required this.estimatedFare,
    required this.expiresAt,
    this.dropoff,
  });

  final PickupPoint pickup;
  final PickupPoint? dropoff;
  final double distanceKm;
  final int estimatedFare;
  final DateTime expiresAt;

  Duration get remaining {
    final r = expiresAt.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }
}

enum RidePhase { idle, incoming, accepted, arrived, boarding, onTrip, done }

class RideState {
  const RideState({
    this.phase = RidePhase.idle,
    this.call,
    this.elapsedSec = 0,
    this.earned = 0,
    this.tripCount = 0,
  });

  final RidePhase phase;
  final PassengerCall? call;
  final int elapsedSec, earned, tripCount;

  RideState copyWith({
    RidePhase? phase,
    PassengerCall? call,
    int? elapsedSec,
    int? earned,
    int? tripCount,
  }) =>
      RideState(
        phase: phase ?? this.phase,
        call: call ?? this.call,
        elapsedSec: elapsedSec ?? this.elapsedSec,
        earned: earned ?? this.earned,
        tripCount: tripCount ?? this.tripCount,
      );
}

// =============================================================================
// 2. 택시 내비 화면 (오픈소스 맵 기반)
// =============================================================================
class TaxiNaviScreen extends StatefulWidget {
  const TaxiNaviScreen({super.key, required this.studentId});

  final String studentId;

  @override
  State<TaxiNaviScreen> createState() => _TaxiNaviScreenState();
}

class _TaxiNaviScreenState extends State<TaxiNaviScreen> {
  final FleetRepository _fleet = FleetHub.current;
  late final VehicleSimulator _sim;
  late final GpsDriveTracker _gps;
  final MapController _mapController = MapController();

  StreamSubscription<Position>? _gpsSub;
  Timer? _timer;
  Timer? _callTimer;
  Timer? _rideTimer;
  Timer? _dropoffResetTimer;
  bool _simMode = false;
  String _gpsStatus = 'GPS 연결 중…';
  String? _lastCallId;

  RideState _ride = const RideState();

  @override
  void initState() {
    super.initState();
    NavAnnouncer.instance.reset();
    _sim = VehicleSimulator(
      id: widget.studentId,
      type: VehicleType.taxi,
      route: kCourseRoute,
    );
    _gps = GpsDriveTracker(
      kCourseRoute,
      onLap: NavAnnouncer.instance.onLap,
    );
    _startGps();
    _timer = Timer.periodic(
      const Duration(milliseconds: AppConfig.tickMs),
      (_) => _tick(),
    );
    _startPassengerEngine();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _callTimer?.cancel();
    _rideTimer?.cancel();
    _dropoffResetTimer?.cancel();
    _gpsSub?.cancel();
    _fleet.remove(widget.studentId);
    super.dispose();
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

  void _toggleMode() {
    setState(() {
      if (_simMode) {
        _simMode = false;
      } else {
        _sim.progress = _gps.progress ?? _sim.progress;
        _sim.speedKmh = _gps.speedKmh;
        _simMode = true;
      }
    });
  }

  double get _progress => _simMode ? _sim.progress : (_gps.progress ?? 0);
  double get _currentMeters => _progress * kCourseRoute.totalMeters;
  double get _speed => _simMode ? _sim.speedKmh : _gps.speedKmh;
  bool get _offRoute => _simMode ? _sim.isOffRoute : _gps.isOffRoute;

  /// 💡 차량의 실제 위·경도 좌표 산출 (LatLng 직접 반환)
  LatLng get _vehicleLatLng {
    if (_simMode) {
      return _sim.position;
    }
    if (_gps.position != null) {
      return _gps.position!;
    }
    return kCourseRoute.pointAt(_progress);
  }

  void _tick() {
    if (!mounted) return;
    if (_simMode) {
      _sim.step(AppConfig.tickMs / 1000);
      _fleet.publish(_sim.toState(location: '시뮬레이션 주행'));
    } else if (_gps.hasFix) {
      _fleet.publish(_gps.toState(
        id: widget.studentId,
        location: _gps.isStale ? 'GPS 신호 약함' : 'GPS 주행 중',
      ));
    }

    // 💡 미터 단위 거리를 기반으로 TTS 턴 체크 호출
    NavAnnouncer.instance.checkTurn(currentMeters: _currentMeters, route: kCourseRoute);
    NavAnnouncer.instance.checkSpeed(_speed);
    NavAnnouncer.instance.checkOffRoute(_offRoute);

    final latLng = _vehicleLatLng;
    try {
      _mapController.move(latLng, _mapController.camera.zoom);
    } catch (_) {}

    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // 승객 호출 엔진
  // ---------------------------------------------------------------------------
  void _startPassengerEngine() {
    void schedule() {
      final sec = AppConfig.callIntervalMinSec +
          math.Random().nextInt(
            AppConfig.callIntervalMaxSec - AppConfig.callIntervalMinSec + 1,
          );
      _callTimer = Timer(Duration(seconds: sec), () {
        if (!mounted) return;
        _generateCall();
        schedule();
      });
    }

    schedule();
    _rideTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _tickRide());
  }

  PickupPoint? _pickCallTarget() {
    final candidates = PickupStore.instance.pickupOnly.where((p) {
      final km = forwardProgress(_progress, p.progress) * AppConfig.routeLengthKm;
      return km >= AppConfig.callMinKm &&
          km <= AppConfig.callMaxKm &&
          p.id != _lastCallId;
    }).toList();
    if (candidates.isEmpty) return null;
    return candidates[math.Random().nextInt(candidates.length)];
  }

  void _generateCall() {
    if (_ride.phase != RidePhase.idle) return;
    final pickup = _pickCallTarget();
    if (pickup == null) return;
    _lastCallId = pickup.id;
    final d =
        forwardProgress(_progress, pickup.progress) * AppConfig.routeLengthKm;
    final call = PassengerCall(
      pickup: pickup,
      distanceKm: d,
      estimatedFare: pickup.baseFare,
      expiresAt: DateTime.now()
          .add(const Duration(seconds: AppConfig.callAcceptWindowSec)),
    );
    setState(() => _ride = _ride.copyWith(
          phase: RidePhase.incoming,
          call: call,
        ));
    NavAnnouncer.instance
        .say('새로운 승객 호출이 도착했습니다', priority: VoicePriority.high);
  }

  void _acceptCall() {
    if (_ride.call == null) return;
    setState(() => _ride = _ride.copyWith(phase: RidePhase.accepted));
    NavAnnouncer.instance
        .say('호출을 수락했습니다. 승차 지점까지 이동하세요', priority: VoicePriority.high);
  }

  void _rejectCall() {
    setState(() => _ride = RideState(
          phase: RidePhase.idle,
          earned: _ride.earned,
          tripCount: _ride.tripCount,
        ));
  }

  void _tickRide() {
    if (!mounted) return;
    final now = DateTime.now();

    switch (_ride.phase) {
      case RidePhase.incoming:
        final call = _ride.call;
        if (call != null && now.isAfter(call.expiresAt)) {
          _rejectCall();
          NavAnnouncer.instance
              .say('호출이 자동 취소되었습니다', priority: VoicePriority.high);
        } else {
          setState(() {});
        }
        break;

      case RidePhase.accepted:
        final p = _ride.call?.pickup;
        if (p != null && _nearProgress(p.progress)) {
          setState(() => _ride = _ride.copyWith(
                phase: RidePhase.arrived,
                elapsedSec: 0,
              ));
          NavAnnouncer.instance
              .say('승차 지점에 도착했습니다', priority: VoicePriority.high);
        }
        break;

      case RidePhase.arrived:
        setState(() => _ride = _ride.copyWith(elapsedSec: _ride.elapsedSec + 1));
        if (_ride.elapsedSec >= 3) {
          setState(() => _ride = _ride.copyWith(phase: RidePhase.boarding));
          NavAnnouncer.instance
              .say('승객이 탑승했습니다', priority: VoicePriority.high);
          _startTripAfterBoarding();
        }
        break;

      case RidePhase.onTrip:
        final d = _ride.call?.dropoff;
        if (d != null && _nearProgress(d.progress)) {
          final fare = _ride.call!.estimatedFare;
          setState(() => _ride = _ride.copyWith(
                phase: RidePhase.done,
                earned: _ride.earned + fare,
                tripCount: _ride.tripCount + 1,
              ));
          NavAnnouncer.instance.say(
            '목적지 도착. 요금 $fare원, 운행이 완료되었습니다',
            priority: VoicePriority.high,
          );
          _dropoffResetTimer?.cancel();
          _dropoffResetTimer = Timer(const Duration(seconds: 3), () {
            if (!mounted) return;
            setState(() => _ride = RideState(
                  phase: RidePhase.idle,
                  earned: _ride.earned,
                  tripCount: _ride.tripCount,
                ));
          });
        }
        break;

      case RidePhase.boarding:
      case RidePhase.idle:
      case RidePhase.done:
        break;
    }
  }

  void _startTripAfterBoarding() {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted || _ride.phase != RidePhase.boarding) return;
      final current = _ride.call;
      if (current == null) return;

      final dropoffs = PickupStore.instance.dropoffOnly
          .where((p) => p.id != current.pickup.id)
          .toList();

      if (dropoffs.isEmpty) {
        setState(() => _ride = RideState(
              phase: RidePhase.idle,
              earned: _ride.earned + current.pickup.baseFare,
              tripCount: _ride.tripCount + 1,
            ));
        NavAnnouncer.instance
            .say('하차 지점이 없어 기본요금으로 종료합니다', priority: VoicePriority.high);
        return;
      }

      final d = dropoffs[math.Random().nextInt(dropoffs.length)];
      final tripKm =
          forwardProgress(current.pickup.progress, d.progress) *
              AppConfig.routeLengthKm;
      final fare = current.pickup.baseFare +
          (tripKm * current.pickup.perKmFare).round();
      final newCall = PassengerCall(
        pickup: current.pickup,
        dropoff: d,
        distanceKm: tripKm,
        estimatedFare: fare,
        expiresAt: current.expiresAt,
      );
      setState(() => _ride = _ride.copyWith(
            phase: RidePhase.onTrip,
            call: newCall,
            elapsedSec: 0,
          ));
      NavAnnouncer.instance.say(
        '${d.name} 방면으로 출발합니다. 예상 요금 $fare원',
        priority: VoicePriority.high,
      );
    });
  }

  bool _nearProgress(double target) {
    final ahead = forwardProgress(_progress, target);
    final lenM = AppConfig.routeLengthKm * 1000;
    final aheadM = ahead * lenM;
    final behindM = (ahead == 0 ? 0.0 : (1 - ahead)) * lenM;
    return aheadM <= AppConfig.pickupArrivalM ||
        behindM <= AppConfig.pickupPassM;
  }

  IconData _iconFor(NavTurnKind kind) => switch (kind) {
        NavTurnKind.left => Icons.turn_left,
        NavTurnKind.right => Icons.turn_right,
        NavTurnKind.slightLeft => Icons.turn_slight_left,
        NavTurnKind.slightRight => Icons.turn_slight_right,
        NavTurnKind.sharpLeft => Icons.turn_sharp_left,
        NavTurnKind.sharpRight => Icons.turn_sharp_right,
        NavTurnKind.uTurn => Icons.u_turn_left,
        NavTurnKind.roundabout => Icons.roundabout_left,
        NavTurnKind.straight => Icons.straight,
      };

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    // 💡 미터 기반 nextTurnAtDistance 호출 및 안전한 방어 처리
    final next = kCourseRoute.nextTurnAtDistance(_currentMeters);
    final nextTurn = next.turn;
    
    final guideIcon = nextTurn == null
        ? Icons.straight
        : _iconFor(nextTurn.kind);
    final guideText = nextTurn == null ? '직진' : nextTurn.kind.label;

    final remainKm = (1 - progress) * AppConfig.routeLengthKm;
    final speed = _speed;
    final etaMin = speed >= 3 ? (remainKm / speed * 60).round() : null;
    final waiting = !_simMode && !_gps.hasFix;
    final topInset = MediaQuery.paddingOf(context).top;

    // 💡 kCourseRoute.points는 이미 LatLng 리스트이므로 그대로 활용
    final routeLatLngs = kCourseRoute.points;

    // 💡 승하차 지점 마커 구성 (p.latLng 활용)
    final pickupMarkers = PickupStore.instance.points.map((p) {
      return Marker(
        point: p.latLng,
        width: 30,
        height: 30,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: p.kind == PickupKind.pickup ? Colors.blue : Colors.orange,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: const Icon(Icons.place, color: Colors.white, size: 14),
        ),
      );
    }).toList();

    final currentPos = _vehicleLatLng;
    final vehicleMarker = Marker(
      point: currentPos,
      width: 42,
      height: 42,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 6)],
        ),
        child: const Icon(
          Icons.navigation,
          color: Colors.blueAccent,
          size: 24,
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      body: ListenableBuilder(
        listenable: _fleet,
        builder: (context, _) => Stack(children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: currentPos,
                initialZoom: 17.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.center_navigation',
                ),
                if (routeLatLngs.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: routeLatLngs,
                        color: Colors.teal,
                        strokeWidth: 5.0,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [...pickupMarkers, vehicleMarker],
                ),
              ],
            ),
          ),
          Positioned(
            top: topInset + 8,
            left: 12,
            right: 12,
            child: _topCard(
              icon: _offRoute ? Icons.warning_rounded : guideIcon,
              title: _offRoute ? '경로 이탈' : '${next.distanceToTurnMeters.toStringAsFixed(0)}m',
              subtitle: _offRoute ? '차선 복귀가 필요합니다' : '$guideText · 다음 안내',
              off: _offRoute,
            ),
          ),
          if (_ride.phase == RidePhase.accepted && _ride.call != null)
            _banner(
              top: topInset + 130,
              color: AppColors.teal,
              icon: Icons.person_pin_circle,
              title: '승차 지점: ${_ride.call!.pickup.name}',
              subtitle:
                  '약 ${(_ride.call!.distanceKm * 1000).toStringAsFixed(0)}m 앞',
            ),
          if (_ride.phase == RidePhase.onTrip && _ride.call?.dropoff != null)
            _banner(
              top: topInset + 130,
              color: AppColors.purple,
              icon: Icons.local_taxi,
              title: '운행 중 → ${_ride.call!.dropoff!.name}',
              subtitle: '요금 ${_ride.call!.estimatedFare}원',
            ),
          if (waiting)
            Positioned(
              top: topInset + 130,
              left: 0,
              right: 0,
              child: const Center(
                child: Chip(
                  avatar: Icon(Icons.gps_not_fixed, size: 18),
                  label: Text('GPS 신호 대기 중 · 하늘이 보이는 곳에서 기다려 주세요'),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _bottomBar(
              speed: speed,
              remainKm: remainKm,
              etaMin: etaMin,
              status: _simMode ? '시뮬레이션 모드' : _gpsStatus,
              progress: progress,
            ),
          ),
          if (_ride.phase == RidePhase.incoming && _ride.call != null)
            _incomingCallCard(_ride.call!),
        ]),
      ),
    );
  }

  Widget _banner({
    required double top,
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
  }) =>
      Positioned(
        top: top,
        left: 16,
        right: 16,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 8),
            ],
          ),
          child: Row(children: [
            Icon(icon, color: Colors.white, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ]),
        ),
      );

  Widget _incomingCallCard(PassengerCall call) {
    final remain = call.remaining.inSeconds;
    final ratio = remain / AppConfig.callAcceptWindowSec;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 130,
      child: Material(
        elevation: 20,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.accent, width: 2),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '호출',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  call.pickup.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '$remain초',
                style: const TextStyle(
                  color: AppColors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.near_me, size: 16, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                '${(call.distanceKm * 1000).toStringAsFixed(0)}m 앞',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(width: 16),
              const Icon(Icons.payments_outlined, size: 16, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                '기본 ${call.pickup.baseFare}원 · 주행요금은 하차 후',
                style: const TextStyle(fontSize: 13),
              ),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation(
                  ratio < 0.3 ? AppColors.red : AppColors.accent,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _rejectCall,
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      side: BorderSide(color: Colors.grey.shade400),
                    ),
                    child: const Text('거절', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _acceptCall,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.teal,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      '수락',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _topCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool off,
  }) =>
      Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(
          color: off ? AppColors.red : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color(0x44000000),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(children: [
          Icon(icon, color: Colors.white, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              NavAnnouncer.instance.enabled ? Icons.volume_up : Icons.volume_off,
              color: Colors.white,
            ),
            onPressed: () => setState(() => NavAnnouncer.instance
                .setEnabled(!NavAnnouncer.instance.enabled)),
          ),
        ]),
      );

  Widget _bottomBar({
    required double speed,
    required double remainKm,
    required int? etaMin,
    required String status,
    required double progress,
  }) {
    final over = speed > AppConfig.speedLimitKmh;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 14,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(
            child: Text(
              status,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Text(
            '${(progress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
          if (_ride.tripCount > 0) ...[
            const SizedBox(width: 8),
            Text(
              '수익 ${_ride.earned}원 · ${_ride.tripCount}건',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.teal,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: Colors.grey.shade200,
            valueColor: const AlwaysStoppedAnimation(Colors.blueAccent),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.red, width: 4),
            ),
            child: Text(
              AppConfig.speedLimitKmh.toStringAsFixed(0),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${speed.toStringAsFixed(0)} km/h',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: over ? AppColors.red : AppColors.dark,
                  ),
                ),
                if (over)
                  const Text(
                    '제한속도 초과',
                    style: TextStyle(color: AppColors.red, fontSize: 12),
                  ),
              ],
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
              '${remainKm.toStringAsFixed(2)} km 남음',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              etaMin == null ? '도착 시간 계산 중' : '약 $etaMin분 후 도착',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            if (_simMode) ...[
              SizedBox(
                width: 76,
                child: ActionButton(
                  icon: Icons.arrow_upward,
                  label: '가속',
                  color: AppColors.taxi,
                  onPressed: () => setState(() => _sim.accelerate(5)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 76,
                child: ActionButton(
                  icon: Icons.arrow_downward,
                  label: '감속',
                  color: Colors.blueGrey,
                  onPressed: () => setState(() => _sim.accelerate(-8)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 76,
                child: ActionButton(
                  icon: Icons.arrow_back,
                  label: '좌',
                  color: AppColors.accent,
                  onPressed: () =>
                      setState(() => _sim.steer(-AppConfig.steerStep)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 76,
                child: ActionButton(
                  icon: Icons.arrow_forward,
                  label: '우',
                  color: AppColors.accent,
                  onPressed: () =>
                      setState(() => _sim.steer(AppConfig.steerStep)),
                ),
              ),
              const SizedBox(width: 6),
            ],
            SizedBox(
              width: 110,
              height: 50,
              child: OutlinedButton(
                onPressed: _toggleMode,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(_simMode ? 'GPS 모드' : '시뮬레이션'),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 110,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.dark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  '안내 종료',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}