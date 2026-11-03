import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../models/vehicle.dart';
import 'calibration_service.dart';

String fleetKey(String id) => id.replaceAll(RegExp(r'[.#$\[\]/]'), '_');

void _logWriteErr(Object e) => debugPrint('RTDB 쓰기 실패: $e');
void _logReadErr(Object e) => debugPrint('RTDB 읽기 실패: $e');

abstract class FleetRepository extends ChangeNotifier {
  Iterable<VehicleState> get vehicles;
  bool isActive(String id);

  void publish(VehicleState s);
  void publishTrail(String id, List<TrailPoint> trail);
  void remove(String id);
}

class LocalFleetRepository extends FleetRepository {
  LocalFleetRepository._();
  static final LocalFleetRepository instance = LocalFleetRepository._();

  final Map<String, VehicleState> _map = {};

  @override
  Iterable<VehicleState> get vehicles => _map.values;

  @override
  bool isActive(String id) => _map.containsKey(fleetKey(id));

  @override
  void publish(VehicleState s) {
    _map[fleetKey(s.id)] = s;
    notifyListeners();
  }

  @override
  void publishTrail(String id, List<TrailPoint> trail) {
    final key = fleetKey(id);
    final v = _map[key];
    if (v != null) _map[key] = v.withTrail(trail);
  }

  @override
  void remove(String id) {
    _map.remove(fleetKey(id));
    notifyListeners();
  }
}

class FirebaseFleetRepository extends FleetRepository {
  FirebaseFleetRepository._() {
    _sub = _root.onValue.listen(_onSnapshot, onError: _logReadErr);
    _trailSub =
        _trailRoot.onValue.listen(_onTrailSnapshot, onError: _logReadErr);
  }

  static final FirebaseFleetRepository instance = FirebaseFleetRepository._();
  static const int _staleSeconds = 20;

  final DatabaseReference _root = FirebaseDatabase.instance.ref('fleet');
  final DatabaseReference _trailRoot =
      FirebaseDatabase.instance.ref('fleet_trail');

  final Map<String, VehicleState> _vehicles = {};
  final Map<String, List<TrailPoint>> _trails = {};
  final Map<String, DateTime> _lastWriteAt = {};
  final Map<String, VehicleState> _lastWritten = {};
  final Set<String> _onDisconnectRegistered = {};
  late final StreamSubscription<DatabaseEvent> _sub;
  late final StreamSubscription<DatabaseEvent> _trailSub;

  @override
  Iterable<VehicleState> get vehicles => _vehicles.values;

  @override
  bool isActive(String id) => _vehicles.containsKey(fleetKey(id));

  @override
  void publish(VehicleState s) {
    final key = fleetKey(s.id);
    _vehicles[key] = s;
    notifyListeners();

    final prev = _lastWritten[key];
    final last = _lastWriteAt[key];
    final now = DateTime.now();
    
    // 거리 계산은 LatLng 간 Haversine 거리 적용
    const distCalc = Distance();
    final moved = prev == null ? double.infinity : distCalc.as(LengthUnit.Meter, prev.position, s.position);
    
    final important = prev == null ||
        prev.isOffRoute != s.isOffRoute ||
        prev.status != s.status ||
        prev.location != s.location ||
        prev.laps != s.laps;
    final idleDue = last == null ||
        now.difference(last).inMilliseconds >= AppConfig.fleetWriteIdleMs;
    if (!important && moved < AppConfig.fleetWriteMoveM && !idleDue) return;

    _lastWriteAt[key] = now;
    _lastWritten[key] = s;
    final node = _root.child(key);
    node.set(_toJson(s)).catchError(_logWriteErr);

    if (_onDisconnectRegistered.add(key)) {
      node.onDisconnect().remove();
      _trailRoot.child(key).onDisconnect().remove();
    }
  }

  @override
  void publishTrail(String id, List<TrailPoint> trail) {
    final node = _trailRoot.child(fleetKey(id));
    if (trail.isEmpty) {
      node.remove();
      return;
    }
    node.set([for (final p in trail) p.toJson()]).catchError(_logWriteErr);
  }

  @override
  void remove(String id) {
    final key = fleetKey(id);
    _vehicles.remove(key);
    _trails.remove(key);
    _lastWriteAt.remove(key);
    _lastWritten.remove(key);
    _onDisconnectRegistered.remove(key);
    _root.child(key).remove();
    _trailRoot.child(key).remove();
    notifyListeners();
  }

  bool _isFresh(Object? stamp, DateTime now) {
    if (stamp is! num) return false;
    final ms = stamp.toInt();
    if (ms < 1000000000000) return false;
    final ageSec =
        now.difference(DateTime.fromMillisecondsSinceEpoch(ms)).inSeconds;
    return ageSec >= -30 && ageSec <= _staleSeconds;
  }

  void _onSnapshot(DatabaseEvent event) {
    final now = DateTime.now();
    final raw = event.snapshot.value;
    final next = <String, VehicleState>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is! Map) return;
        if (!_isFresh(v['updatedAt'], now)) return;
        final key = k.toString();
        next[key] = _fromJson(v, _trails[key] ?? const []);
      });
    }
    _vehicles
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void _onTrailSnapshot(DatabaseEvent event) {
    final raw = event.snapshot.value;
    _trails.clear();
    if (raw is Map) {
      raw.forEach((k, v) {
        final Iterable<dynamic> items =
            v is List ? v : (v is Map ? v.values : const []);
        final pts = <TrailPoint>[];
        for (final e in items) {
          if (e is List && e.length >= 3) {
            try {
              pts.add(TrailPoint.fromJson(e));
            } catch (_) {}
          }
        }
        _trails[k.toString()] = pts;
      });
    }
    for (final key in _vehicles.keys.toList()) {
      _vehicles[key] = _vehicles[key]!.withTrail(_trails[key] ?? const []);
    }
    notifyListeners();
  }

  Map<String, dynamic> _toJson(VehicleState s) => {
        'id': s.id,
        'type': s.type.name,
        'progress': s.progress,
        'speedKmh': s.speedKmh,
        'avgSpeedKmh': s.avgSpeedKmh,
        'laps': s.laps,
        'lat': s.position.latitude,
        'lon': s.position.longitude,
        'deviation': s.deviation,
        'isOffRoute': s.isOffRoute,
        'location': s.location,
        'status': s.status,
        'updatedAt': ServerValue.timestamp,
      };

  VehicleState _fromJson(Map v, List<TrailPoint> trail) {
    final lat = _d(v['lat'] ?? v['y']);
    final lon = _d(v['lon'] ?? v['x']);
    return VehicleState(
      id: (v['id'] ?? '').toString(),
      type: VehicleType.values.firstWhere(
        (t) => t.name == v['type'],
        orElse: () => VehicleType.taxi,
      ),
      progress: _d(v['progress']),
      speedKmh: _d(v['speedKmh']),
      avgSpeedKmh: _d(v['avgSpeedKmh']),
      laps: (v['laps'] as num?)?.toInt() ?? 0,
      position: LatLng(lat, lon),
      deviation: _d(v['deviation']),
      isOffRoute: v['isOffRoute'] == true,
      location: (v['location'] ?? '').toString(),
      status: (v['status'] ?? '').toString(),
      trail: trail,
    );
  }

  static double _d(Object? v) => v is num ? v.toDouble() : 0;

  @override
  void dispose() {
    _sub.cancel();
    _trailSub.cancel();
    super.dispose();
  }
}

class FleetHub {
  FleetHub._();
  static bool firebaseReady = false;

  static FleetRepository get current => firebaseReady
      ? FirebaseFleetRepository.instance
      : LocalFleetRepository.instance;
}