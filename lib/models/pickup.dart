import 'package:latlong2/latlong.dart';

enum PickupKind { pickup, dropoff, both }

class PickupPoint {
  const PickupPoint({
    required this.id,
    required this.name,
    required this.progress,
    required this.latLng,
    this.baseFare = 3000,
    this.perKmFare = 1000,
    this.kind = PickupKind.both,
  });

  final String id, name;
  final double progress;

  /// 💡 기존 픽셀 Offset 대신 실제 지구 위·경도(LatLng) 좌표를 사용합니다.
  final LatLng latLng;

  // 하위 호환성 및 기존 데이터 연동을 위한 편의 getter
  double get lat => latLng.latitude;
  double get lon => latLng.longitude;

  final int baseFare, perKmFare;
  final PickupKind kind;

  /// 소스 코드에 붙여넣을 수 있는 `PickupPoint(...)` 문자열.
  String toDartCode() => '''
  PickupPoint(
    id: '${_escape(id)}',
    name: '${_escape(name)}',
    progress: ${progress.toStringAsFixed(4)},
    latLng: LatLng(${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}),
    baseFare: $baseFare,
    perKmFare: $perKmFare,
    kind: PickupKind.${kind.name},
  ),''';

  static String _escape(String s) => s.replaceAll("'", "\\'");

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'progress': progress,
        'lat': lat,
        'lon': lon,
        'baseFare': baseFare,
        'perKmFare': perKmFare,
        'kind': kind.name,
      };

  factory PickupPoint.fromJson(Map<String, dynamic> j) {
    // 기존 JSON 키('x', 'y')와 신규 키('lat', 'lon') 모두 유연하게 호환 처리
    final latitude = (j['lat'] as num?)?.toDouble() ??
        (j['y'] as num?)?.toDouble() ??
        37.2315;
    final longitude = (j['lon'] as num?)?.toDouble() ??
        (j['x'] as num?)?.toDouble() ??
        126.7795;

    return PickupPoint(
      id: j['id'] as String,
      name: j['name'] as String,
      progress: (j['progress'] as num).toDouble(),
      latLng: LatLng(latitude, longitude),
      baseFare: (j['baseFare'] as num?)?.toInt() ?? 3000,
      perKmFare: (j['perKmFare'] as num?)?.toInt() ?? 1000,
      kind: PickupKind.values.firstWhere(
        (k) => k.name == j['kind'],
        orElse: () => PickupKind.both,
      ),
    );
  }
}
