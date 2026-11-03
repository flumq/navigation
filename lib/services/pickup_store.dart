import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/pickup.dart';

/// 코드에 고정된 기본 승차/하차 지점. 현장에서 등록한 지점은 기기에 저장된다.
const List<PickupPoint> kPickupPoints = [
  PickupPoint(
    id: 'P72849',
    name: '아파트단지',
    progress: 0.4480,
    latLng: LatLng(37.22962104, 126.78055364),
    baseFare: 3800,
    perKmFare: 1000,
    kind: PickupKind.pickup,
  ),
  PickupPoint(
    id: 'P36836',
    name: '버스베이형 정류장앞',
    progress: 0.3074,
    latLng: LatLng(37.23096624, 126.78123188),
    baseFare: 3000,
    perKmFare: 1000,
    kind: PickupKind.both,
  ),
  PickupPoint(
    id: 'P87828',
    name: '버스정류소',
    progress: 0.1029,
    latLng: LatLng(37.23341624, 126.78064516),
    baseFare: 3000,
    perKmFare: 1000,
    kind: PickupKind.both,
  ),
];

class PickupStore extends ChangeNotifier {
  PickupStore._();
  static final PickupStore instance = PickupStore._();
  static const _key = 'pickup_points_v1';

  final List<PickupPoint> _points = [];

  List<PickupPoint> get points => List.unmodifiable(_points);

  List<PickupPoint> get pickupOnly =>
      _points.where((p) => p.kind != PickupKind.dropoff).toList();

  List<PickupPoint> get dropoffOnly =>
      _points.where((p) => p.kind != PickupKind.pickup).toList();

  Future<void> load() async {
    _points
      ..clear()
      ..addAll(kPickupPoints);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final stored = (jsonDecode(raw) as List)
            .map((e) => PickupPoint.fromJson(Map<String, dynamic>.from(e)));
        for (final p in stored) {
          if (!_points.any((x) => x.id == p.id)) _points.add(p);
        }
      }
    } catch (e) {
      debugPrint('승차 지점 로드 실패: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_points.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> add(PickupPoint p) async {
    _points.add(p);
    await _save();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _points.removeWhere((p) => p.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    _points.clear();
    await _save();
    notifyListeners();
  }

  String exportAsDartCode() {
    if (_points.isEmpty) return '// 등록된 승차 지점이 없습니다.';
    final buf = StringBuffer()
      ..writeln('// ─────────────────────────────────────────────')
      ..writeln('// 승차/하차 지점 (현장 등록)')
      ..writeln('// pickup_store.dart 의 kPickupPoints 에 붙여넣으세요.')
      ..writeln('// ─────────────────────────────────────────────')
      ..writeln('const List<PickupPoint> kPickupPoints = [');
    for (final p in _points) {
      buf.writeln(p.toDartCode());
    }
    buf.writeln('];');
    return buf.toString();
  }
}