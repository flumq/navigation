import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../core/config.dart';
import '../map/map_layers.dart';
import '../models/course.dart';
import '../services/calibration_service.dart';
import '../services/gps_service.dart';
import '../widgets/common.dart';

/// 오차(px) 수준에 따른 색. 경로 탭과 현장 보정 화면이 함께 쓴다.
Color residualColor(double r) =>
    r > 15 ? AppColors.red : (r > 8 ? Colors.orange : Colors.green);

class CalibrationWaypoint {
  const CalibrationWaypoint({
    required this.progress,
    required this.label,
    required this.hint,
  });

  final double progress;
  final String label, hint;

  Offset get mapPosition => kCourseRoute.pointAt(progress);
}

final List<CalibrationWaypoint> kCalibrationWaypoints = [
  const CalibrationWaypoint(
    progress: 0.00,
    label: '출발점',
    hint: '코스 시작 지점 · 지도 상단 중앙',
  ),
  const CalibrationWaypoint(
    progress: 0.10,
    label: '동쪽 진입',
    hint: '지도 우측 상단 · 파란 지붕 옆',
  ),
  const CalibrationWaypoint(
    progress: 0.45,
    label: '동쪽 중간',
    hint: '지도 우측 중간 · 큰 나무 아래',
  ),
  const CalibrationWaypoint(
    progress: 0.65,
    label: '남쪽 코너',
    hint: '지도 우측 하단 · 주차장 입구',
  ),
  const CalibrationWaypoint(
    progress: 0.90,
    label: '서쪽 코너',
    hint: '지도 좌측 상단 · 정문 방향',
  ),
];

class FieldCalibrationScreen extends StatefulWidget {
  const FieldCalibrationScreen({super.key});

  @override
  State<FieldCalibrationScreen> createState() => _FieldCalibrationScreenState();
}

class _FieldCalibrationScreenState extends State<FieldCalibrationScreen> {
  StreamSubscription<Position>? _sub;
  Position? _current;
  int _index = 0;
  final Set<int> _captured = {};
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
      if (mounted) setState(() => _current = p);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _capture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final avg = await averageFix();
      if (avg == null) {
        _toast('GPS 취득 실패');
        return;
      }
      if (avg.acc > AppConfig.gpsAccuracyLimitM) {
        _toast('정확도 ${avg.acc.toStringAsFixed(1)}m · 재시도');
        return;
      }
      final wp = kCalibrationWaypoints[_index];
      final m = wp.mapPosition;
      
      // 기존 점 리스트에 새로운 현장 보정 점 추가 후 저장
      final nextPoints = [
        ...CalibrationManager.instance.points,
        CalibrationPoint(lat: avg.lat, lon: avg.lon, x: m.dx, y: m.dy),
      ];
      await CalibrationManager.instance.saveAndApply(nextPoints);

      setState(() {
        _captured.add(_index);
        if (_index < kCalibrationWaypoints.length - 1) _index++;
      });
      _toast('${wp.label} 등록 · 정확도 ${avg.acc.toStringAsFixed(1)}m');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wp = kCalibrationWaypoints[_index];
    final current = CalibrationManager.instance;
    final rms = current.affineMap?.rmsPixels;
    final cur = _current;
    final curOk = cur != null && cur.accuracy <= AppConfig.gpsAccuracyLimitM;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('현장 보정 모드'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_index + 1} / ${kCalibrationWaypoints.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      wp.label,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(
                  wp.hint,
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: AppConfig.mapAspectRatio,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(children: [
                      Image.asset(AppConfig.mapAsset, fit: BoxFit.fill),
                      CustomPaint(
                        size: Size.infinite,
                        painter: _CoursePreviewPainter(
                          route: kCourseRoute,
                          target: wp.mapPosition,
                          captured: [
                            for (final i in _captured)
                              kCalibrationWaypoints[i].mapPosition,
                          ],
                        ),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(
                cur == null
                    ? Icons.gps_not_fixed
                    : (curOk ? Icons.gps_fixed : Icons.gps_off),
                color: cur == null
                    ? Colors.grey
                    : (curOk ? Colors.green : Colors.orange),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  cur == null
                      ? 'GPS 신호 대기 중…'
                      : '정확도 ${cur.accuracy.toStringAsFixed(1)} m · '
                          '${cur.speed.toStringAsFixed(1)} m/s',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 68,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _capture,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.teal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              icon: Icon(
                _busy ? Icons.hourglass_top : Icons.pin_drop,
                size: 28,
              ),
              label: Text(
                _busy ? 'GPS 평균 취득 중…' : '여기에 도착! (${wp.label} 등록)',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '최대 10초 안에 GPS를 5회 샘플링해 평균값으로 등록합니다.\n'
            '정확도 10m 이하일 때 누르는 것이 좋습니다.',
            style: TextStyle(fontSize: 11, color: Colors.black45),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (current.points.isNotEmpty) ...[
            const SectionTitle('수집된 기준점'),
            for (var i = 0; i < current.points.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Builder(builder: (_) {
                    final r = current.residualPxFor(current.points[i]);
                    final meters = r == null ? null : r * kMetersPerMapPx;
                    return Row(children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: AppColors.primary,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '위도 ${current.points[i].lat.toStringAsFixed(6)}, '
                              '경도 ${current.points[i].lon.toStringAsFixed(6)}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            if (r != null)
                              Text(
                                '오차 ${r.toStringAsFixed(1)}px ≈ ${meters!.toStringAsFixed(1)}m',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: residualColor(r),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ]);
                  }),
                ),
              ),
          ],
          if (rms != null) ...[
            const SizedBox(height: 8),
            AppCard(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(
                  rms < 8 ? Icons.check_circle : Icons.info,
                  color: rms < 8 ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    rms < 8
                        ? '보정 완료 · RMS ${rms.toStringAsFixed(1)}px '
                            '(약 ${(rms * kMetersPerMapPx).toStringAsFixed(1)}m)'
                        : 'RMS ${rms.toStringAsFixed(1)}px · 기준점을 더 넓게 배치하세요',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _CoursePreviewPainter extends CustomPainter {
  _CoursePreviewPainter({
    required this.route,
    required this.target,
    required this.captured,
  });

  final RouteGeometry route;
  final Offset target;
  final List<Offset> captured;

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

    for (final c in captured) {
      final p = Offset(c.dx * size.width, c.dy * size.height);
      canvas.drawCircle(p, 6, Paint()..color = Colors.green);
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    final t = Offset(target.dx * size.width, target.dy * size.height);
    canvas.drawCircle(
      t,
      14,
      Paint()..color = AppColors.red.withValues(alpha: 0.25),
    );
    canvas.drawCircle(t, 7, Paint()..color = AppColors.red);
    canvas.drawCircle(
      t,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CoursePreviewPainter old) =>
      old.target != target || old.captured.length != captured.length;
}