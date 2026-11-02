import 'dart:async';


import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../core/config.dart';
import '../map/map_layers.dart';
import '../models/course.dart';
import '../models/pickup.dart';
import '../services/gps_service.dart';
import '../services/pickup_store.dart';
import '../widgets/common.dart';

import '../services/calibration_service.dart';


class PickupRegistrationScreen extends StatefulWidget {
  const PickupRegistrationScreen({super.key});

  @override
  State<PickupRegistrationScreen> createState() =>
      _PickupRegistrationScreenState();
}

class _PickupRegistrationScreenState extends State<PickupRegistrationScreen> {
  StreamSubscription<Position>? _sub;
  Position? _current;
  Offset? _projected;
  double? _progress;
  double _projErrorM = 0;
  final _nameC = TextEditingController();
  PickupKind _kind = PickupKind.both;
  int _baseFare = 3000;
  int _perKmFare = 1000;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _startGps();
  }

  Future<void> _startGps() async {
    final err = await ensureGpsReady();
    if (!mounted) return;
    if (err != null) {
      _toast(err);
      return;
    }
    _sub = gpsStream().listen((p) {
      if (!mounted || p.accuracy > AppConfig.gpsAccuracyLimitM) return;
      final mapPos = gpsToMap(p.latitude, p.longitude);
      final proj = kCourseRoute.project(mapPos);
      setState(() {
        _current = p;
        _projected = mapPos;
        _progress = proj.progress;
        _projErrorM = proj.distance;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _nameC.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _register() async {
    if (_busy) return;
    final name = _nameC.text.trim();
    if (name.isEmpty) {
      _toast('지점 이름을 입력하세요');
      return;
    }
    final progress = _progress;
    if (progress == null) {
      _toast('GPS 대기 중');
      return;
    }
    if (_projErrorM > 30) {
      _toast('코스에서 ${_projErrorM.toStringAsFixed(0)}m 이격 · 코스 근처에서 등록');
      return;
    }
    setState(() => _busy = true);
    try {
      final avg = await averageFix();
      if (avg == null) {
        _toast('GPS 취득 실패');
        return;
      }
      final id = 'P${DateTime.now().millisecondsSinceEpoch % 100000}';
      await PickupStore.instance.add(PickupPoint(
        id: id,
        name: name,
        progress: progress,
        mapPosition: kCourseRoute.pointAt(progress),
        lat: avg.lat,
        lon: avg.lon,
        baseFare: _baseFare,
        perKmFare: _perKmFare,
        kind: _kind,
      ));
      _toast('등록 완료 · progress=${progress.toStringAsFixed(3)}');
      _nameC.clear();
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final progress = _progress;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('승차 지점 등록'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: AppConfig.mapAspectRatio,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(children: [
                Image.asset(AppConfig.mapAsset, fit: BoxFit.fill),
                CustomPaint(
                  size: Size.infinite,
                  painter: _PickupPreviewPainter(
                    route: kCourseRoute,
                    current: _projected,
                    projected:
                        progress == null ? null : kCourseRoute.pointAt(progress),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                    cur == null ? Icons.gps_not_fixed : Icons.gps_fixed,
                    color: cur == null ? Colors.grey : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cur == null
                          ? 'GPS 신호 대기 중…'
                          : '정확도 ${cur.accuracy.toStringAsFixed(1)}m · '
                              '코스 이격 ${_projErrorM.toStringAsFixed(1)}m',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ]),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '코스 위치 ${(progress * 100).toStringAsFixed(1)}% 지점에 자동 매핑',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Column(children: [
              TextField(
                controller: _nameC,
                decoration: const InputDecoration(
                  labelText: '지점 이름',
                  hintText: '예: 정문 앞, 3층 출구',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<PickupKind>(
                segments: const [
                  ButtonSegment(value: PickupKind.pickup, label: Text('승차')),
                  ButtonSegment(value: PickupKind.dropoff, label: Text('하차')),
                  ButtonSegment(value: PickupKind.both, label: Text('둘 다')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _baseFare.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '기본요금'),
                    onChanged: (v) => _baseFare = int.tryParse(v) ?? 3000,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: _perKmFare.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'km당 요금'),
                    onChanged: (v) => _perKmFare = int.tryParse(v) ?? 1000,
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 60,
            child: ElevatedButton.icon(
              onPressed: _busy || progress == null ? null : _register,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.teal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              icon: Icon(
                _busy ? Icons.hourglass_top : Icons.add_location_alt,
                size: 24,
              ),
              label: Text(
                _busy ? 'GPS 평균 취득 중…' : '여기에 승차 지점 등록',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickupPreviewPainter extends CustomPainter {
  _PickupPreviewPainter({required this.route, this.current, this.projected});

  final RouteGeometry route;
  final Offset? current, projected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      routePath(route.points, size, closed: true),
      Paint()
        ..color = AppColors.teal
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    final t = projected;
    if (t != null) {
      final p = Offset(t.dx * size.width, t.dy * size.height);
      canvas.drawCircle(p, 9, Paint()..color = AppColors.red.withValues(alpha: 0.25));
      canvas.drawCircle(p, 5, Paint()..color = AppColors.red);
      canvas.drawCircle(
        p,
        5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    final c = current;
    if (c != null) {
      final cp = Offset(c.dx * size.width, c.dy * size.height);
      canvas.drawCircle(cp, 6, Paint()..color = Colors.blue);
      canvas.drawCircle(
        cp,
        6,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      if (t != null) {
        final tp = Offset(t.dx * size.width, t.dy * size.height);
        canvas.drawLine(
          cp,
          tp,
          Paint()
            ..color = Colors.blue
            ..strokeWidth = 1.2
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PickupPreviewPainter old) =>
      old.current != current || old.projected != projected;
}