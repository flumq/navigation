import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/geo.dart';

// =============================================================================
// 1. 기본 투영 상수
// =============================================================================
const double kOriginLat = 37.23151423;
const double kOriginLng = 126.77961225;
final double kLngScale = 111320.0 * math.cos(kOriginLat * math.pi / 180);
const double kLatScale = kLatMetersPerDeg;

const double kUE = 2.2526872434e-03;
const double kUN = 8.7912166286e-06;
const double kUC = 0.6356014028;
const double kVE = 6.4089305627e-06;
const double kVN = -1.6422432449e-03;
const double kVC = 0.4213655422;

const double kMetersPerMapPx = 0.4023; // 💡 에러 해결용 상수 추가

Offset gpsToMap(double lat, double lon) =>
    CalibrationManager.instance.projectGps(lat, lon);

(double, double) mapToGps(Offset n) =>
    CalibrationManager.instance.unprojectMap(n);

double mapDistanceM(Offset a, Offset b) {
  final g1 = mapToGps(a);
  final g2 = mapToGps(b);
  return haversineM(g1.$1, g1.$2, g2.$1, g2.$2);
}

// =============================================================================
// 2. 기준점 모델
// =============================================================================
class CalibrationPoint {
  const CalibrationPoint({
    required this.lat,
    required this.lon,
    required this.x,
    required this.y,
  });

  final double lat, lon, x, y;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'x': x, 'y': y};

  factory CalibrationPoint.fromJson(Map<String, dynamic> j) => CalibrationPoint(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
      );
}

const List<CalibrationPoint> kDefaultCalibrationPoints = [
  CalibrationPoint(lat: 37.2337012, lon: 126.7794569, x: 0.6201, y: 0.0185),
  CalibrationPoint(lat: 37.2334850, lon: 126.7806577, x: 0.8412, y: 0.0862),
  CalibrationPoint(lat: 37.2296761, lon: 126.7805222, x: 0.8160, y: 0.7544),
  CalibrationPoint(lat: 37.2311761, lon: 126.7796902, x: 0.6629, y: 0.4695),
  CalibrationPoint(lat: 37.2328656, lon: 126.7783817, x: 0.4220, y: 0.1394),
  CalibrationPoint(lat: 37.2297653, lon: 126.7796423, x: 0.6540, y: 0.7170),
  CalibrationPoint(lat: 37.2296002, lon: 126.7807454, x: 0.8571, y: 0.7733),
  CalibrationPoint(lat: 37.2298062, lon: 126.7811023, x: 0.9229, y: 0.7458),
  CalibrationPoint(lat: 37.2326864, lon: 126.7810391, x: 0.9114, y: 0.2364),
  CalibrationPoint(lat: 37.2328622, lon: 126.7787337, x: 0.4868, y: 0.1487),
];

// =============================================================================
// 3. 어파인 변환 클래스
// =============================================================================
class AffineMap {
  AffineMap(List<CalibrationPoint> input) {
    if (input.length < 3) throw ArgumentError('기준점 3개 이상 필요');
    _lat0 = input.map((p) => p.lat).reduce((a, b) => a + b) / input.length;
    _lon0 = input.map((p) => p.lon).reduce((a, b) => a + b) / input.length;
    _cosLat = math.cos(_lat0 * math.pi / 180);

    final rowsFwd = <List<double>>[];
    final vx = <double>[], vy = <double>[];
    final rowsInv = <List<double>>[];
    final vdx = <double>[], vdy = <double>[];

    for (final p in input) {
      final l = _toLocal(p.lat, p.lon);
      rowsFwd.add([l.dx, l.dy, 1]);
      vx.add(p.x);
      vy.add(p.y);
      rowsInv.add([p.x, p.y, 1]);
      vdx.add(l.dx);
      vdy.add(l.dy);
    }
    _x = _solve3(rowsFwd, vx);
    _y = _solve3(rowsFwd, vy);
    _invDx = _solve3(rowsInv, vdx);
    _invDy = _solve3(rowsInv, vdy);

    var sumSq = 0.0;
    for (final p in input) {
      final q = project(p.lat, p.lon);
      final dx = (q.dx - p.x) * AppConfig.mapWidthPx;
      final dy = (q.dy - p.y) * AppConfig.mapHeightPx;
      sumSq += dx * dx + dy * dy;
    }
    rmsPixels = math.sqrt(sumSq / input.length);
  }

  late final double _lat0, _lon0, _cosLat;
  late final List<double> _x, _y, _invDx, _invDy;
  late final double rmsPixels;

  Offset _toLocal(double lat, double lon) => Offset(
        (lon - _lon0) * 111320.0 * _cosLat,
        (lat - _lat0) * kLatMetersPerDeg,
      );

  Offset project(double lat, double lon) {
    final l = _toLocal(lat, lon);
    return Offset(
      _x[0] * l.dx + _x[1] * l.dy + _x[2],
      _y[0] * l.dx + _y[1] * l.dy + _y[2],
    );
  }

  (double, double) unproject(Offset n) {
    final dx = _invDx[0] * n.dx + _invDx[1] * n.dy + _invDx[2];
    final dy = _invDy[0] * n.dx + _invDy[1] * n.dy + _invDy[2];
    return (
      _lat0 + dy / kLatMetersPerDeg,
      _lon0 + dx / (111320.0 * _cosLat),
    );
  }

  static List<double> _solve3(List<List<double>> rows, List<double> values) {
    final n = List.generate(3, (_) => List<double>.filled(3, 0));
    final rhs = List<double>.filled(3, 0);
    for (var r = 0; r < rows.length; r++) {
      for (var i = 0; i < 3; i++) {
        rhs[i] += rows[r][i] * values[r];
        for (var j = 0; j < 3; j++) {
          n[i][j] += rows[r][i] * rows[r][j];
        }
      }
    }
    final a = List.generate(3, (i) => [...n[i], rhs[i]]);
    for (var col = 0; col < 3; col++) {
      var pivot = col;
      for (var r = col + 1; r < 3; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) throw StateError('기준점이 한 직선');
      final tmp = a[col];
      a[col] = a[pivot];
      a[pivot] = tmp;
      final div = a[col][col];
      for (var j = col; j < 4; j++) {
        a[col][j] /= div;
      }
      for (var r = 0; r < 3; r++) {
        if (r == col) continue;
        final f = a[r][col];
        for (var j = col; j < 4; j++) {
          a[r][j] -= f * a[col][j];
        }
      }
    }
    return [a[0][3], a[1][3], a[2][3]];
  }
}

// =============================================================================
// 4. 보정 관리자
// =============================================================================
class CalibrationManager extends ChangeNotifier {
  CalibrationManager._();
  static final CalibrationManager instance = CalibrationManager._();
  static const _storageKey = 'center_map_calibration_v4';

  final List<CalibrationPoint> _points = [];
  AffineMap? _map;

  double scaleX = 1.0;
  double scaleY = 1.0;
  double offsetX = 0.0;
  double offsetY = 0.0;

  List<CalibrationPoint> get points => List.unmodifiable(_points);
  AffineMap? get affineMap => _map;

  Offset projectGps(double lat, double lon) {
    Offset base;
    if (_map != null) {
      base = _map!.project(lat, lon);
    } else {
      final d = _projectDefault(lat, lon);
      base = _points.isEmpty ? d : d + _avgOffset;
    }

    final adjustedX = (base.dx - 0.5) * scaleX + 0.5 + offsetX;
    final adjustedY = (base.dy - 0.5) * scaleY + 0.5 + offsetY;
    return Offset(adjustedX, adjustedY);
  }

  (double, double) unprojectMap(Offset p) {
    final unscaledX = (p.dx - offsetX - 0.5) / scaleX + 0.5;
    final unscaledY = (p.dy - offsetY - 0.5) / scaleY + 0.5;
    final target = Offset(unscaledX, unscaledY);

    if (_map != null) return _map!.unproject(target);
    final adjusted = _points.isEmpty ? target : target - _avgOffset;
    return _unprojectDefault(adjusted);
  }

  Offset get _avgOffset {
    var sx = 0.0, sy = 0.0;
    for (final c in _points) {
      final proj = _projectDefault(c.lat, c.lon);
      sx += c.x - proj.dx;
      sy += c.y - proj.dy;
    }
    return Offset(sx / _points.length, sy / _points.length);
  }

  Offset _projectDefault(double lat, double lon) {
    final e = (lon - kOriginLng) * kLngScale;
    final n = (lat - kOriginLat) * kLatScale;
    return Offset(kUE * e + kUN * n + kUC, kVE * e + kVN * n + kVC);
  }

  (double, double) _unprojectDefault(Offset p) {
    const a = kUE, b = kUN, c = kVE, d = kVN;
    const det = a * d - b * c;
    final du = p.dx - kUC, dv = p.dy - kVC;
    final e = (d * du - b * dv) / det;
    final n = (-c * du + a * dv) / det;
    return (kOriginLat + n / kLatScale, kOriginLng + e / kLngScale);
  }

  /// 💡 [필수 추가됨] 기준점 하나의 잔차(px) 계산 메서드
  double? residualPxFor(CalibrationPoint c) {
    if (_map == null && _points.isEmpty) return null;
    final proj = projectGps(c.lat, c.lon);
    final dx = (proj.dx - c.x) * AppConfig.mapWidthPx;
    final dy = (proj.dy - c.y) * AppConfig.mapHeightPx;
    return math.sqrt(dx * dx + dy * dy);
  }

  String exportToJson() {
    final data = {
      'scaleX': scaleX,
      'scaleY': scaleY,
      'offsetX': offsetX,
      'offsetY': offsetY,
      'points': _points.map((p) => p.toJson()).toList(),
    };
    return jsonEncode(data);
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);

      List<CalibrationPoint> list = [];
      if (raw == null) {
        list = kDefaultCalibrationPoints;
      } else {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map && decoded.containsKey('points')) {
            scaleX = (decoded['scaleX'] as num?)?.toDouble() ?? 1.0;
            scaleY = (decoded['scaleY'] as num?)?.toDouble() ?? 1.0;
            offsetX = (decoded['offsetX'] as num?)?.toDouble() ?? 0.0;
            offsetY = (decoded['offsetY'] as num?)?.toDouble() ?? 0.0;
            list = (decoded['points'] as List)
                .map((e) =>
                    CalibrationPoint.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          } else if (decoded is List) {
            list = decoded
                .map((e) =>
                    CalibrationPoint.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          }
        } catch (_) {
          list = kDefaultCalibrationPoints;
        }
      }

      _points.clear();
      _points.addAll(list);
      _map = list.length >= 3 ? AffineMap(list) : null;
      notifyListeners();
    } catch (e) {
      debugPrint('기준점 로드 실패: $e');
    }
  }

  Future<void> saveAndApply(List<CalibrationPoint> next) async {
    final map = next.length >= 3 ? AffineMap(next) : null;
    final prefs = await SharedPreferences.getInstance();

    final data = {
      'scaleX': scaleX,
      'scaleY': scaleY,
      'offsetX': offsetX,
      'offsetY': offsetY,
      'points': next.map((p) => p.toJson()).toList(),
    };

    await prefs.setString(_storageKey, jsonEncode(data));
    _points.clear();
    _points.addAll(next);
    _map = map;
    notifyListeners();
  }

  Future<void> updateScaleAndOffset(
      double sx, double sy, double ox, double oy) async {
    scaleX = sx;
    scaleY = sy;
    offsetX = ox;
    offsetY = oy;
    await saveAndApply(_points);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    _points.clear();
    _map = null;
    scaleX = 1.0;
    scaleY = 1.0;
    offsetX = 0.0;
    offsetY = 0.0;
    notifyListeners();
  }
}
