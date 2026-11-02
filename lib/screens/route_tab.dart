import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../core/config.dart';
import '../map/map_layers.dart';
import '../models/course.dart';
import '../services/calibration_service.dart';
import '../services/gps_import.dart';
import '../services/gps_service.dart';
import '../services/pickup_store.dart';
import '../widgets/common.dart';
import 'field_calibration_screen.dart';
import 'pickup_manager_sheet.dart';
import 'pickup_registration_screen.dart';

// =============================================================================
// 1. 좌표 입력 다이얼로그
// =============================================================================
class CoordDialog extends StatefulWidget {
  const CoordDialog({
    super.key,
    required this.title,
    required this.info,
    this.lat,
    this.lon,
  });

  final String title;
  final String info;
  final double? lat;
  final double? lon;

  @override
  State<CoordDialog> createState() => _CoordDialogState();
}

class _CoordDialogState extends State<CoordDialog> {
  late final TextEditingController _latC =
      TextEditingController(text: widget.lat?.toStringAsFixed(8) ?? '');
  late final TextEditingController _lonC =
      TextEditingController(text: widget.lon?.toStringAsFixed(8) ?? '');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _latC.dispose();
    _lonC.dispose();
    super.dispose();
  }

  String? _validate(String? v, double limit) {
    final n = double.tryParse(v?.trim() ?? '');
    return n == null || n.abs() > limit ? '범위 확인' : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.info, style: const TextStyle(fontSize: 12)),
              TextFormField(
                controller: _latC,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(labelText: '위도 (-90 ~ 90)'),
                validator: (v) => _validate(v, 90),
              ),
              TextFormField(
                controller: _lonC,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(labelText: '경도 (-180 ~ 180)'),
                validator: (v) => _validate(v, 180),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              if (_formKey.currentState!.validate()) {
                Navigator.pop(context, (
                  lat: double.parse(_latC.text.trim()),
                  lon: double.parse(_lonC.text.trim()),
                ));
              }
            },
            child: const Text('확인'),
          ),
        ],
      );
}

// =============================================================================
// 2. 경로 탭
// =============================================================================
class RouteTab extends StatefulWidget {
  const RouteTab({super.key});

  @override
  State<RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends State<RouteTab> {
  Offset? _selected;
  bool _showRoute = true;
  String _message = '지도를 눌러 기준점을 등록하거나, 현장 보정 모드를 사용하세요.';

  StreamSubscription<Position>? _gpsSub;
  Offset? _liveGps;
  double _liveAccuracy = 0;
  bool _liveOn = false;

  @override
  void dispose() {
    _gpsSub?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<({double lat, double lon})?> _coordDialog({
    required String title,
    required String info,
    double? lat,
    double? lon,
  }) =>
      showDialog<({double lat, double lon})>(
        context: context,
        builder: (_) =>
            CoordDialog(title: title, info: info, lat: lat, lon: lon),
      );

  Future<void> _apply(List<CalibrationPoint> next, String action) async {
    try {
      await CalibrationManager.instance.saveAndApply(next);
      final map = CalibrationManager.instance.affineMap;
      if (!mounted) return;
      setState(() => _message = map == null
          ? '$action · ${next.length}점 (평행이동 보정)'
          : '$action · ${next.length}점 · RMS ${map.rmsPixels.toStringAsFixed(1)}px');
    } catch (e) {
      _toast('적용 실패: $e');
    }
  }

  Future<void> _addCalibration() async {
    final sel = _selected;
    if (sel == null) {
      _toast('지도를 먼저 탭하세요.');
      return;
    }
    final c = await _coordDialog(
      title: '기준점 GPS 입력',
      info: 'x=${sel.dx.toStringAsFixed(5)}, y=${sel.dy.toStringAsFixed(5)}',
    );
    if (c == null) return;
    await _apply([
      ...CalibrationManager.instance.points,
      CalibrationPoint(lat: c.lat, lon: c.lon, x: sel.dx, y: sel.dy),
    ], '기준점 등록');
    if (mounted) setState(() => _selected = null);
  }

  Future<void> _addFromCurrentGps() async {
    final sel = _selected;
    if (sel == null) {
      _toast('지도를 먼저 탭하세요.');
      return;
    }
    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 15),
      );
      if (p.accuracy > AppConfig.gpsAccuracyLimitM) {
        _toast('정확도 ${p.accuracy.toStringAsFixed(1)}m · 잠시 후 재시도');
        return;
      }
      await _apply([
        ...CalibrationManager.instance.points,
        CalibrationPoint(
          lat: p.latitude,
          lon: p.longitude,
          x: sel.dx,
          y: sel.dy,
        ),
      ], '현재 GPS로 등록');
      if (mounted) setState(() => _selected = null);
    } catch (e) {
      _toast('GPS 실패: $e');
    }
  }

  Future<void> _editCalibration(int index) async {
    final current = CalibrationManager.instance.points;
    final old = current[index];
    final c = await _coordDialog(
      title: '기준점 ${String.fromCharCode(65 + index)}',
      info: 'x=${old.x.toStringAsFixed(4)}, y=${old.y.toStringAsFixed(4)}',
      lat: old.lat,
      lon: old.lon,
    );
    if (c == null) return;
    final next = List<CalibrationPoint>.from(current);
    next[index] = CalibrationPoint(lat: c.lat, lon: c.lon, x: old.x, y: old.y);
    await _apply(next, '기준점 수정');
  }

  Future<void> _removeCalibration(int index) async {
    final next = List<CalibrationPoint>.from(CalibrationManager.instance.points)
      ..removeAt(index);
    await _apply(next, '기준점 삭제');
  }

  Future<void> _clearCalibration() async {
    await CalibrationManager.instance.clear();
    if (mounted) setState(() => _message = '기준점 초기화');
  }

  Future<void> _toggleLive() async {
    if (_liveOn) {
      await _gpsSub?.cancel();
      _gpsSub = null;
      if (mounted) {
        setState(() {
          _liveOn = false;
          _liveGps = null;
        });
      }
      return;
    }
    final err = await ensureGpsReady();
    if (!mounted) return;
    if (err != null) {
      _toast(err);
      return;
    }
    _gpsSub = gpsStream().listen((p) {
      if (!mounted || p.accuracy > 100) return;
      setState(() {
        _liveGps = gpsToMap(p.latitude, p.longitude);
        _liveAccuracy = p.accuracy;
      });
    });
    setState(() => _liveOn = true);
  }

  Future<void> _openFieldCalibration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FieldCalibrationScreen()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openPickupRegistration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PickupRegistrationScreen()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openPickupManager() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PickupManagerSheet(),
    );
    if (mounted) setState(() {});
  }

  Widget _coordBar() {
    final sel = _selected;
    final text = sel == null
        ? '지도를 누르면 GPS 좌표가 계산됩니다'
        : (() {
            final g = mapToGps(sel);
            return '위도 ${g.$1.toStringAsFixed(7)} · 경도 ${g.$2.toStringAsFixed(7)}\n'
                'x=${sel.dx.toStringAsFixed(4)}, y=${sel.dy.toStringAsFixed(4)}';
          })();

    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
          if (sel != null)
            OutlinedButton(
              onPressed: () {
                final g = mapToGps(sel);
                Clipboard.setData(ClipboardData(
                  text: '${g.$1.toStringAsFixed(7)}, ${g.$2.toStringAsFixed(7)}',
                ));
                _toast('좌표 복사');
              },
              child: const Text('복사'),
            ),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 40,
          child: ElevatedButton.icon(
            onPressed: _toggleLive,
            icon: Icon(
              _liveOn ? Icons.gps_fixed : Icons.gps_not_fixed,
              size: 16,
            ),
            label: Text(_liveOn
                ? 'GPS 실시간 ON · ${_liveAccuracy.toStringAsFixed(0)}m'
                : 'GPS 실시간 위치 보기'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _liveOn ? AppColors.teal : null,
              foregroundColor: _liveOn ? Colors.white : null,
            ),
          ),
        ),
      ]),
    );
  }

  Color _residualColor(double r) =>
      r > 15 ? AppColors.red : (r > 8 ? Colors.orange : Colors.green);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          CalibrationManager.instance,
          GpsTrackStore.instance,
          PickupStore.instance,
        ]),
        builder: (context, _) {
          final calib = CalibrationManager.instance;
          final points = calib.points;
          return Column(children: [
            AppHeader(title: '코스 경로 · 현장 도구', subtitle: _message),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _coordBar(),
            ),
            Expanded(
              flex: 8,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    color: Colors.white,
                    child: MapView(
                      showScaleBar: true,
                      onTapNormalized: (p) => setState(() => _selected = p),
                      layers: [
                        const VectorBaseLayer(),
                        if (_showRoute)
                          RouteLayer(
                            points: kCourseRoute.points,
                            color: AppColors.teal.withValues(alpha: 0.8),
                          ),
                        TrackLayer(tracks: GpsTrackStore.instance.tracks),
                        PickupLayer(points: PickupStore.instance.points),
                        if (_liveGps != null)
                          LiveGpsLayer(
                            position: _liveGps!,
                            accuracyM: _liveAccuracy,
                          ),
                        CalibrationLayer(points: points, selected: _selected),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  Row(children: [
                    Expanded(
                      child: ActionButton(
                        icon: Icons.add_location_alt,
                        label: '수동 등록',
                        onPressed: _addCalibration,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ActionButton(
                        icon: Icons.gps_fixed,
                        label: 'GPS로 등록',
                        color: AppColors.teal,
                        onPressed: _addFromCurrentGps,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ActionButton(
                        icon: Icons.restart_alt,
                        label: '초기화',
                        color: AppColors.dark,
                        onPressed: _clearCalibration,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: ActionButton(
                        icon: Icons.directions_walk,
                        label: '현장 보정',
                        color: AppColors.purple,
                        onPressed: _openFieldCalibration,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ActionButton(
                        icon: Icons.person_pin_circle,
                        label: '승차 등록',
                        color: AppColors.accent,
                        onPressed: _openPickupRegistration,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ActionButton(
                        icon: Icons.list_alt,
                        label: '승차 관리',
                        color: AppColors.bus,
                        onPressed: _openPickupManager,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  
                  // 💡 [추가됨] 스케일 미세 조정 컨트롤러 영역 (왼쪽 빗길코스 밀림 현상 해결용)
                  AppCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                           mainAxisAlignment: MainAxisAlignment.spaceBetween, // 올바른 상수명
                          children: [
                            const Text('맵 스케일 미세 조정', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            TextButton(
                              onPressed: () => calib.updateScaleAndOffset(1.0, 1.0, 0.0, 0.0),
                              child: const Text('기본값 리셋', style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('가로(X):', style: TextStyle(fontSize: 11)),
                            Expanded(
                              child: Slider(
                                value: calib.scaleX,
                                min: 0.8,
                                max: 1.2,
                                divisions: 40,
                                label: calib.scaleX.toStringAsFixed(3),
                                onChanged: (v) {
                                  calib.updateScaleAndOffset(v, calib.scaleY, calib.offsetX, calib.offsetY);
                                },
                              ),
                            ),
                            Text(calib.scaleX.toStringAsFixed(2), style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('세로(Y):', style: TextStyle(fontSize: 11)),
                            Expanded(
                              child: Slider(
                                value: calib.scaleY,
                                min: 0.8,
                                max: 1.2,
                                divisions: 40,
                                label: calib.scaleY.toStringAsFixed(3),
                                onChanged: (v) {
                                  calib.updateScaleAndOffset(calib.scaleX, v, calib.offsetX, calib.offsetY);
                                },
                              ),
                            ),
                            Text(calib.scaleY.toStringAsFixed(2), style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.copy, size: 14),
                              label: const Text('보정값 JSON 복사', style: TextStyle(fontSize: 11)),
                              onPressed: () {
                                final jsonStr = calib.exportToJson();
                                Clipboard.setData(ClipboardData(text: jsonStr));
                                _toast('보정 데이터 JSON 클립보드 복사 완료!');
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),
                  AppCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('코스 노선 표시'),
                      value: _showRoute,
                      onChanged: (v) => setState(() => _showRoute = v),
                    ),
                  ),
                  const SectionTitle('기준점(GCP) 목록'),
                  if (points.isEmpty)
                    const AppCard(
                      child: Text(
                        '등록된 기준점이 없습니다. 1점만 등록해도 평행이동 보정됩니다.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  for (var i = 0; i < points.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AppCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          onTap: () => _editCalibration(i),
                          onLongPress: () => _removeCalibration(i),
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: AppColors.primary,
                            child: Text(
                              String.fromCharCode(65 + i),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          title: Text(
                            '위도 ${points[i].lat.toStringAsFixed(6)}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Builder(builder: (_) {
                            final r = calib.residualPxFor(points[i]);
                            final meters =
                                r == null ? null : r * kMetersPerMapPx;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '경도 ${points[i].lon.toStringAsFixed(6)} · '
                                  'x=${points[i].x.toStringAsFixed(3)}, '
                                  'y=${points[i].y.toStringAsFixed(3)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                if (r != null)
                                  Text(
                                    '오차 ${r.toStringAsFixed(1)}px ≈ ${meters!.toStringAsFixed(1)}m',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _residualColor(r),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                              ],
                            );
                          }),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ]);
        },
      );
}