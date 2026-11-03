import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';

import '../core/config.dart';
import '../core/geo.dart';
import '../services/calibration_service.dart';
import '../services/gps_import.dart';
import '../services/gps_service.dart';
import '../widgets/common.dart';

class MeasureTab extends StatefulWidget {
  const MeasureTab({super.key});

  @override
  State<MeasureTab> createState() => _MeasureTabState();
}

class _MeasureTabState extends State<MeasureTab> {
  StreamSubscription<Position>? _sub;
  bool _busy = false;
  int _rejected = 0;
  String _message = 'GPS 기록 또는 JSON 파일을 불러오세요.';

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _setMessage(String msg) {
    if (mounted) setState(() => _message = msg);
  }

  Future<void> _startRecording() async {
    if (_sub != null) return;
    final err = await ensureGpsReady();
    if (err != null) {
      _toast(err);
      return;
    }

    final track = GpsTrack(
      name: 'GPS 기록 ${hms(DateTime.now())}',
      color: GpsTrackStore.instance.nextColor(),
    );
    GpsTrackStore.instance.add(track);
    _rejected = 0;

    _sub = gpsStream().listen(
      (p) {
        if (p.accuracy > AppConfig.gpsAccuracyLimitM) {
          _rejected++;
          _setMessage(
            '정확도 부족(${p.accuracy.toStringAsFixed(1)}m) · 제외 $_rejected개',
          );
          return;
        }
        GpsTrackStore.instance.appendSample(
          track,
          GpsSample(
            time: p.timestamp,
            lat: p.latitude,
            lon: p.longitude,
            speedKmh: (p.speed < 0 ? 0 : p.speed) * 3.6,
            accuracyM: p.accuracy,
          ),
        );
        _setMessage(
          '기록 중 · ${track.samples.length}점 · 정확도 ${p.accuracy.toStringAsFixed(1)}m',
        );
      },
      onError: (Object e) => _setMessage('GPS 오류: $e'),
    );
    _setMessage('GPS 기록을 시작했습니다.');
  }

  Future<void> _stopRecording() async {
    await _sub?.cancel();
    _sub = null;
    _setMessage('GPS 기록을 종료했습니다.');
  }

  Future<void> _importJson() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: true,
        withData: true,
      );
      if (result == null) return;

      var added = 0, points = 0;
      for (final f in result.files) {
        var bytes = f.bytes;
        if (bytes == null && f.path != null) {
          bytes = await XFile(f.path!).readAsBytes();
        }
        if (bytes == null || bytes.isEmpty) {
          _toast('${f.name}: 파일을 읽을 수 없습니다.');
          continue;
        }
        final text =
            utf8.decode(bytes, allowMalformed: true).replaceFirst('\uFEFF', '');
        final samples = parseGpsSamples(jsonDecode(text));
        if (samples.length < 2) {
          _toast('${f.name}: 유효한 좌표 없음');
          continue;
        }
        GpsTrackStore.instance.add(GpsTrack(
          name: f.name.replaceAll(RegExp(r'\.json$', caseSensitive: false), ''),
          color: GpsTrackStore.instance.nextColor(),
          samples: samples,
        ));
        added++;
        points += samples.length;
      }
      _setMessage('$added개 파일 · 유효 점 $points개');
    } catch (e) {
      _toast('JSON 불러오기 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportJson() async {
    final tracks = GpsTrackStore.instance.tracks;
    if (tracks.every((t) => t.samples.isEmpty)) {
      _toast('내보낼 기록이 없습니다.');
      return;
    }
    try {
      final data = tracks.map((t) => {
            'name': t.name,
            'samples': t.samples.map((s) => s.toJson()).toList(),
          }).toList();

      final jsonStr = jsonEncode(data);
      final name = 'gps_tracks_${DateTime.now().millisecondsSinceEpoch}.json';
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      await Share.shareXFiles(
        [XFile.fromData(bytes, mimeType: 'application/json', name: name)],
        text: '센터 GPS 주행 궤적 JSON',
      );
    } catch (e) {
      _toast('JSON 내보내기 실패: $e');
    }
  }

  Future<void> _exportCsv() async {
    final tracks = GpsTrackStore.instance.tracks;
    if (tracks.every((t) => t.samples.isEmpty)) {
      _toast('저장할 기록이 없습니다.');
      return;
    }
    try {
      final map = CalibrationManager.instance.affineMap;
      final b = StringBuffer(
        'track,timestamp,latitude,longitude,speed_kmh,accuracy_m,map_x,map_y\n',
      );
      for (final t in tracks) {
        for (final s in t.samples) {
          final p = map?.project(s.lat, s.lon);
          b.writeln([
            t.name.replaceAll(',', ' '),
            s.time.toIso8601String(),
            s.lat,
            s.lon,
            s.speedKmh.toStringAsFixed(2),
            s.accuracyM.toStringAsFixed(2),
            p?.dx.toStringAsFixed(5) ?? '',
            p?.dy.toStringAsFixed(5) ?? '',
          ].join(','));
        }
      }
      final name = 'gps_tracks_${DateTime.now().millisecondsSinceEpoch}.csv';
      final bytes = Uint8List.fromList(utf8.encode('\uFEFF$b'));
      await Share.shareXFiles(
        [XFile.fromData(bytes, mimeType: 'text/csv', name: name)],
        text: '센터 GPS 주행 궤적 CSV',
      );
    } catch (e) {
      _toast('CSV 공유 실패: $e');
    }
  }

  Future<void> _clearAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('궤적 전체 삭제'),
        content: const Text('모든 궤적을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (yes == true) {
      GpsTrackStore.instance.clear();
      _setMessage('궤적을 모두 삭제했습니다.');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.zero,
        children: [
          AppHeader(title: 'GPS 기록', subtitle: _message),
          const SectionTitle('기록 · 불러오기'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: ActionButton(
                    icon: Icons.fiber_manual_record,
                    label: '기록 시작',
                    color: AppColors.red,
                    onPressed: _sub == null ? _startRecording : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ActionButton(
                    icon: Icons.stop,
                    label: '기록 종료',
                    color: AppColors.dark,
                    onPressed: _sub != null ? _stopRecording : null,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: ActionButton(
                    icon: Icons.file_open,
                    label: _busy ? '불러오는 중…' : 'JSON 불러오기',
                    onPressed: _busy ? null : _importJson,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ActionButton(
                    icon: Icons.save_alt,
                    label: 'JSON 내보내기',
                    color: AppColors.primary,
                    onPressed: _exportJson,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: ActionButton(
                    icon: Icons.table_chart,
                    label: 'CSV 내보내기',
                    color: AppColors.teal,
                    onPressed: _exportCsv,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _clearAll,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('궤적 전체 삭제'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.red,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          const SectionTitle('궤적 목록'),
          ListenableBuilder(
            listenable: GpsTrackStore.instance,
            builder: (_, __) {
              final tracks = GpsTrackStore.instance.tracks;
              if (tracks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: AppCard(
                    child: Text(
                      '불러온 궤적이 없습니다.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  for (final t in tracks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AppCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 8,
                            backgroundColor: t.color,
                          ),
                          title: Text(
                            t.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${t.samples.length}점 · 약 ${t.lengthKm.toStringAsFixed(2)} km',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => GpsTrackStore.instance.remove(t),
                          ),
                        ),
                      ),
                    ),
                ]),
              );
            },
          ),
          const SizedBox(height: 32),
        ],
      );
}