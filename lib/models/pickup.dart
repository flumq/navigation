import 'dart:ui' show Offset;

enum PickupKind { pickup, dropoff, both }

class PickupPoint {
  const PickupPoint({
    required this.id,
    required this.name,
    required this.progress,
    required this.mapPosition,
    this.lat,
    this.lon,
    this.baseFare = 3000,
    this.perKmFare = 1000,
    this.kind = PickupKind.both,
  });

  final String id, name;
  final double progress;

  /// 정규화 지도 좌표(0~1).
  final Offset mapPosition;
  final double? lat, lon;
  final int baseFare, perKmFare;
  final PickupKind kind;

  /// 소스 코드에 붙여넣을 수 있는 `PickupPoint(...)` 문자열.
  String toDartCode() => '''
  PickupPoint(
    id: '${_escape(id)}',
    name: '${_escape(name)}',
    progress: ${progress.toStringAsFixed(4)},
    mapPosition: const Offset(${mapPosition.dx.toStringAsFixed(4)}, ${mapPosition.dy.toStringAsFixed(4)}),
    lat: ${lat?.toStringAsFixed(8) ?? 'null'},
    lon: ${lon?.toStringAsFixed(8) ?? 'null'},
    baseFare: $baseFare,
    perKmFare: $perKmFare,
    kind: PickupKind.${kind.name},
  ),''';

  static String _escape(String s) => s.replaceAll("'", "\\'");

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'progress': progress,
        'x': mapPosition.dx,
        'y': mapPosition.dy,
        'lat': lat,
        'lon': lon,
        'baseFare': baseFare,
        'perKmFare': perKmFare,
        'kind': kind.name,
      };

  factory PickupPoint.fromJson(Map<String, dynamic> j) => PickupPoint(
        id: j['id'] as String,
        name: j['name'] as String,
        progress: (j['progress'] as num).toDouble(),
        mapPosition: Offset(
          (j['x'] as num).toDouble(),
          (j['y'] as num).toDouble(),
        ),
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        baseFare: (j['baseFare'] as num?)?.toInt() ?? 3000,
        perKmFare: (j['perKmFare'] as num?)?.toInt() ?? 1000,
        kind: PickupKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => PickupKind.both,
        ),
      );
}