import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/geo.dart';

// =============================================================================
// 1. 모델
// =============================================================================
class GpsSample {
  const GpsSample({
    required this.time,
    required this.lat,
    required this.lon,
    required this.speedKmh,
    required this.accuracyM,
  });

  final DateTime time;
  final double lat;
  final double lon;
  final double speedKmh;
  final double accuracyM;

  // 💡 [필수] JSON 내보내기를 위한 메서드 추가 확인
  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'lat': lat,
        'lon': lon,
        'speedKmh': speedKmh,
        'accuracyM': accuracyM,
      };
}

class GpsTrack {
  GpsTrack({
    required this.name,
    required this.color,
    List<GpsSample>? samples,
  }) : samples = samples ?? [];

  final String name;
  final Color color;
  final List<GpsSample> samples;

  double get lengthKm {
    var m = 0.0;
    for (var i = 1; i < samples.length; i++) {
      m += haversineM(
        samples[i - 1].lat,
        samples[i - 1].lon,
        samples[i].lat,
        samples[i].lon,
      );
    }
    return m / 1000;
  }
}

// =============================================================================
// 2. 트랙 저장소 (화면에 떠 있는 기록 목록)
// =============================================================================
class GpsTrackStore extends ChangeNotifier {
  GpsTrackStore._();
  static final GpsTrackStore instance = GpsTrackStore._();

  static const List<Color> _palette = [
    Colors.yellowAccent,
    Colors.pinkAccent,
    Colors.lightGreenAccent,
    Colors.orangeAccent,
    Colors.purpleAccent,
    Colors.white,
  ];

  final List<GpsTrack> _tracks = [];

  List<GpsTrack> get tracks => List.unmodifiable(_tracks);

  Color nextColor() => _palette[_tracks.length % _palette.length];

  void add(GpsTrack t) {
    _tracks.add(t);
    notifyListeners();
  }

  void appendSample(GpsTrack t, GpsSample s) {
    t.samples.add(s);
    notifyListeners();
  }

  void remove(GpsTrack t) {
    _tracks.remove(t);
    notifyListeners();
  }

  void clear() {
    _tracks.clear();
    notifyListeners();
  }
}

// =============================================================================
// 3. JSON 파싱 (다양한 키 이름과 시간 형식을 허용)
// =============================================================================

/// 여러 키 이름 중 처음으로 숫자로 읽히는 값을 돌려준다. 문자열 숫자도 허용.
double? _num(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v is num) return v.toDouble();
    if (v is String) {
      final n = double.tryParse(v.trim());
      if (n != null) return n;
    }
  }
  return null;
}

/// 초 단위 또는 밀리초 단위 숫자, 혹은 ISO 문자열을 시각으로 바꾼다.
DateTime? _parseTime(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    final ms = v.abs() > 1e11 ? v.toInt() : (v * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  if (v is String) {
    final n = num.tryParse(v.trim());
    if (n != null) return _parseTime(n);
    return DateTime.tryParse(v.trim())?.toLocal();
  }
  return null;
}

GpsSample? _sampleFromMap(Map raw) {
  final m = <String, dynamic>{
    for (final e in raw.entries) e.key.toString().toLowerCase(): e.value,
  };

  final type = m['type']?.toString().toLowerCase();
  if (type != null && type != 'fix') return null;

  final lat = _num(m, ['latitude', 'lat', 'latitudedegrees']);
  final lon = _num(m, ['longitude', 'lon', 'lng', 'longitudedegrees']);
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;

  final time = _parseTime(
    m['unixtimemillis'] ?? m['timestamp'] ?? m['time'] ?? m['datetime'],
  );
  if (time == null) return null;

  final acc = _num(
    m,
    ['accuracymeters', 'accuracy_m', 'accuracy_meters', 'accuracy'],
  );
  if (acc != null && acc > AppConfig.gpsAccuracyLimitM) return null;

  final mps = _num(m, ['speedmps', 'speed_mps']);
  final kmh = mps != null ? mps * 3.6 : (_num(m, ['speed_kmh']) ?? 0);

  return GpsSample(
    time: time,
    lat: lat,
    lon: lon,
    speedKmh: kmh.isFinite ? math.max(0.0, kmh) : 0,
    accuracyM: acc ?? AppConfig.gpsAccuracyLimitM,
  );
}

/// 임의의 JSON 트리에서 GPS 샘플을 모아 시간순으로 정렬하고,
/// 비정상적으로 빠른 점(튀는 값)을 걸러낸다.
List<GpsSample> parseGpsSamples(dynamic root) {
  final found = <GpsSample>[];

  void walk(dynamic node) {
    if (node is Map) {
      final s = _sampleFromMap(node);
      if (s != null) found.add(s);
      for (final v in node.values) {
        if (v is Map || v is List) walk(v);
      }
    } else if (node is List) {
      for (final v in node) {
        if (v is Map || v is List) walk(v);
      }
    }
  }

  walk(root);
  found.sort((a, b) => a.time.compareTo(b.time));

  final out = <GpsSample>[];
  for (final s in found) {
    if (out.isEmpty) {
      out.add(s);
      continue;
    }
    final prev = out.last;
    final dt = s.time.difference(prev.time).inMilliseconds / 1000;
    if (dt <= 0) continue;
    final mps = haversineM(prev.lat, prev.lon, s.lat, s.lon) / dt;
    if (mps > AppConfig.gpsMaxSpeedMps) continue;
    out.add(s);
  }
  return out;
}
