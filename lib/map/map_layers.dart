import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/geo.dart';
import '../models/pickup.dart';
import '../models/vehicle.dart';
import '../services/calibration_service.dart';
import '../services/gps_import.dart';

// =============================================================================
// 1. 공용 경로/선 그리기
// =============================================================================

/// 정규화 좌표 목록을 화면 크기에 맞춘 Path로 바꾼다.
Path routePath(List<Offset> pts, Size size, {bool closed = false}) {
  final path = Path();
  for (var i = 0; i < pts.length; i++) {
    final x = pts[i].dx * size.width, y = pts[i].dy * size.height;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  if (closed) path.close();
  return path;
}

class _Polyline {
  const _Polyline(this.points, this.color, this.width);

  /// null은 선을 끊는 지점이다.
  final List<Offset?> points;
  final Color color;
  final double width;
}

class _PolylinePainter extends CustomPainter {
  _PolylinePainter(this.lines);

  final List<_Polyline> lines;

  @override
  void paint(Canvas canvas, Size size) {
    for (final line in lines) {
      final paint = Paint()
        ..color = line.color
        ..strokeWidth = line.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var open = false;
      for (final p in line.points) {
        if (p == null) {
          open = false;
          continue;
        }
        final x = p.dx * size.width, y = p.dy * size.height;
        if (!open) {
          path.moveTo(x, y);
          open = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PolylinePainter old) => old.lines != lines;
}

bool _insideMap(Offset m) =>
    m.dx >= 0 && m.dx <= 1 && m.dy >= 0 && m.dy <= 1;

// =============================================================================
// 2. 레이어 기반 클래스
// =============================================================================
class MapViewport {
  const MapViewport(this.size);

  final Size size;

  Offset at(Offset normalized) =>
      Offset(normalized.dx * size.width, normalized.dy * size.height);
}

abstract class MapLayer {
  const MapLayer();

  Widget build(MapViewport vp);
}

class VectorBaseLayer extends MapLayer {
  const VectorBaseLayer();

  @override
  Widget build(MapViewport vp) => Positioned.fill(
        child: Image.asset(AppConfig.mapAsset, fit: BoxFit.fill),
      );
}

class RouteLayer extends MapLayer {
  const RouteLayer({required this.points, required this.color});

  final List<Offset> points;
  final Color color;

  @override
  Widget build(MapViewport vp) {
    final closed = <Offset?>[...points, if (points.isNotEmpty) points.first];
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _PolylinePainter([_Polyline(closed, color, 3)]),
        ),
      ),
    );
  }
}

class TrackLayer extends MapLayer {
  const TrackLayer({required this.tracks});

  final List<GpsTrack> tracks;

  @override
  Widget build(MapViewport vp) {
    final lines = <_Polyline>[];
    for (final track in tracks) {
      final pts = <Offset?>[];
      for (final s in track.samples) {
        if (s.accuracyM > AppConfig.gpsAccuracyLimitM) {
          pts.add(null);
          continue;
        }
        final p = gpsToMap(s.lat, s.lon);
        pts.add(_insideMap(p) ? p : null);
      }
      lines.add(_Polyline(pts, track.color, 2));
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(painter: _PolylinePainter(lines)),
      ),
    );
  }
}

/// 서버에서 받은 버스 궤적(참조선).
class TrailLayer extends MapLayer {
  const TrailLayer({required this.trails});

  final List<({List<TrailPoint> trail, Color color, double width})> trails;

  @override
  Widget build(MapViewport vp) {
    final lines = <_Polyline>[];
    for (final t in trails) {
      final pts = <Offset?>[];
      for (final p in t.trail) {
        final m = gpsToMap(p.lat, p.lon);
        pts.add(_insideMap(m) ? m : null);
      }
      if (pts.isNotEmpty) lines.add(_Polyline(pts, t.color, t.width));
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(painter: _PolylinePainter(lines)),
      ),
    );
  }
}

class CalibrationLayer extends MapLayer {
  const CalibrationLayer({required this.points, this.selected});

  final List<CalibrationPoint> points;
  final Offset? selected;

  @override
  Widget build(MapViewport vp) => Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _CalibrationPainter(points, selected)),
        ),
      );
}

class _CalibrationPainter extends CustomPainter {
  _CalibrationPainter(this.points, this.selected);

  final List<CalibrationPoint> points;
  final Offset? selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < points.length; i++) {
      final c = points[i];
      final p = Offset(c.x * size.width, c.y * size.height);
      canvas.drawCircle(p, 5, Paint()..color = Colors.orangeAccent);
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(65 + i),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(color: Colors.black, blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p + const Offset(7, -14));
    }

    final sel = selected;
    if (sel != null) {
      final p = Offset(sel.dx * size.width, sel.dy * size.height);
      final cross = Paint()
        ..color = AppColors.red
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      const arm = 16.0;
      canvas.drawLine(p + const Offset(-arm, 0), p + const Offset(arm, 0), cross);
      canvas.drawLine(p + const Offset(0, -arm), p + const Offset(0, arm), cross);
      canvas.drawCircle(p, 10, cross);
      canvas.drawCircle(p, 2.5, Paint()..color = AppColors.red);
    }
  }

  @override
  bool shouldRepaint(covariant _CalibrationPainter old) => true;
}

class VehicleLayer extends MapLayer {
  const VehicleLayer({required this.vehicles});

  final List<VehicleState> vehicles;

  @override
  Widget build(MapViewport vp) => Positioned.fill(
        child: Stack(clipBehavior: Clip.none, children: [
          for (final v in vehicles)
            Positioned(
              left: vp.at(v.position).dx - 30,
              top: vp.at(v.position).dy - 14,
              child: VehicleMarker(state: v),
            ),
        ]),
      );
}

class VehicleMarker extends StatelessWidget {
  const VehicleMarker({super.key, required this.state});

  final VehicleState state;

  @override
  Widget build(BuildContext context) {
    final isTaxi = state.type == VehicleType.taxi;
    final color = state.isOffRoute
        ? AppColors.red
        : (isTaxi ? AppColors.taxi : AppColors.bus);
    final icon = state.isOffRoute
        ? Icons.warning_rounded
        : (isTaxi ? Icons.local_taxi : Icons.directions_bus);
    return Tooltip(
      message: '[${state.type.name.toUpperCase()}] ${state.id} | '
          '${state.speedKmh.toStringAsFixed(1)} km/h '
          '· 평균 ${state.avgSpeedKmh.toStringAsFixed(1)} km/h '
          '· ${state.laps}랩',
      child: Chip(
        avatar: Icon(icon, color: Colors.white, size: 14),
        backgroundColor: color,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
        label: Text(
          state.id,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

double _accuracyRadiusPx(Offset n, double meters, Size size) {
  final safe = meters <= 0 ? 8.0 : meters;
  final (lat, lon) = mapToGps(n);
  final edge = gpsToMap(lat + safe / kLatMetersPerDeg, lon);
  final dx = (edge.dx - n.dx) * size.width;
  final dy = (edge.dy - n.dy) * size.height;
  final r = math.sqrt(dx * dx + dy * dy);
  if (!r.isFinite || r == 0) {
    return (safe / (AppConfig.mapWidthPx * kMetersPerMapPx) * size.width)
        .clamp(6.0, size.longestSide)
        .toDouble();
  }
  return r.clamp(6.0, size.longestSide).toDouble();
}

class LiveGpsLayer extends MapLayer {
  const LiveGpsLayer({required this.position, required this.accuracyM});

  final Offset position;
  final double accuracyM;

  @override
  Widget build(MapViewport vp) {
    final p = vp.at(position);
    final accuracyPx = _accuracyRadiusPx(position, accuracyM, vp.size);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(children: [
          Positioned(
            left: p.dx - accuracyPx,
            top: p.dy - accuracyPx,
            child: Container(
              width: accuracyPx * 2,
              height: accuracyPx * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.withValues(alpha: 0.12),
                border: Border.all(
                  color: Colors.blue.withValues(alpha: 0.45),
                  width: 1.5,
                ),
              ),
            ),
          ),
          Positioned(
            left: p.dx - 9,
            top: p.dy - 9,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: const [
                  BoxShadow(color: Color(0x60000000), blurRadius: 4),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class PickupLayer extends MapLayer {
  const PickupLayer({required this.points});

  final List<PickupPoint> points;

  @override
  Widget build(MapViewport vp) => Positioned.fill(
        child: IgnorePointer(
          child: Stack(children: [
            for (final p in points)
              Positioned(
                left: vp.at(p.mapPosition).dx - 10,
                top: vp.at(p.mapPosition).dy - 10,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _pickupColor(p.kind),
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Color(0x60000000), blurRadius: 4),
                    ],
                  ),
                  child: Icon(_pickupIcon(p.kind), color: Colors.white, size: 12),
                ),
              ),
          ]),
        ),
      );
}

/// 승차/하차/겸용 지점의 색과 아이콘. 화면과 오버레이에서 공용으로 쓴다.
Color pickupColor(PickupKind k) => switch (k) {
      PickupKind.pickup => AppColors.teal,
      PickupKind.dropoff => AppColors.purple,
      PickupKind.both => AppColors.accent,
    };

IconData pickupIcon(PickupKind k) => switch (k) {
      PickupKind.pickup => Icons.person_pin_circle,
      PickupKind.dropoff => Icons.flag,
      PickupKind.both => Icons.swap_horiz,
    };

Color _pickupColor(PickupKind k) => pickupColor(k);
IconData _pickupIcon(PickupKind k) => pickupIcon(k);

// =============================================================================
// 3. 지도 본체
// =============================================================================
class MapView extends StatelessWidget {
  const MapView({
    super.key,
    required this.layers,
    this.onTapNormalized,
    this.showScaleBar = false,
  });

  final List<MapLayer> layers;
  final ValueChanged<Offset>? onTapNormalized;
  final bool showScaleBar;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;
          var h = maxW / AppConfig.mapAspectRatio;
          var w = maxW;
          if (h > maxH) {
            h = maxH;
            w = h * AppConfig.mapAspectRatio;
          }
          final size = Size(w, h);
          final vp = MapViewport(size);

          return Center(
            child: Stack(clipBehavior: Clip.none, children: [
              SizedBox(
                width: w,
                height: h,
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 12,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: onTapNormalized == null
                        ? null
                        : (d) {
                            final n = Offset(
                              d.localPosition.dx / size.width,
                              d.localPosition.dy / size.height,
                            );
                            if (_insideMap(n)) onTapNormalized!(n);
                          },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [for (final l in layers) l.build(vp)],
                    ),
                  ),
                ),
              ),
              if (showScaleBar)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: _ScaleBar(
                    metersPerPx: AppConfig.mapWidthPx * kMetersPerMapPx / w,
                  ),
                ),
            ]),
          );
        },
      );
}

class _ScaleBar extends StatelessWidget {
  const _ScaleBar({required this.metersPerPx});

  final double metersPerPx;

  @override
  Widget build(BuildContext context) {
    const targetMeters = 50.0;
    final barPx = targetMeters / metersPerPx;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.dark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: barPx, height: 4, color: AppColors.dark),
          const SizedBox(height: 2),
          const Text(
            '50 m',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}