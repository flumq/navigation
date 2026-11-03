import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../services/gps_service.dart';

/// OSM 실제 지도 위에서 GPS 원본 위치와 기준 코스의 정합 상태를 확인한다.
/// 이미지 지도 좌표 보정값을 새로 저장하지 않는다.
class FieldCalibrationScreen extends StatefulWidget {
  const FieldCalibrationScreen({super.key});

  @override
  State<FieldCalibrationScreen> createState() => _FieldCalibrationScreenState();
}

class _FieldCalibrationScreenState extends State<FieldCalibrationScreen> {
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _sub;
  Position? _current;
  String? _gpsError;

  @override
  void initState() {
    super.initState();
    _startGps();
  }

  Future<void> _startGps() async {
    final error = await ensureGpsReady();
    if (!mounted) return;
    if (error != null) {
      setState(() => _gpsError = error);
      return;
    }
    _sub = gpsStream(distanceFilter: 1).listen(
      (position) {
        if (!mounted) return;
        setState(() {
          _current = position;
          _gpsError = null;
        });
      },
      onError: (Object error) {
        if (mounted) setState(() => _gpsError = 'GPS 수신 오류: $error');
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final currentPoint = current == null
        ? null
        : LatLng(current.latitude, current.longitude);
    final projection = currentPoint == null
        ? null
        : kCourseRoute.projectLatLng(currentPoint);
    final accuracyOk = current != null &&
        current.accuracy <= AppConfig.gpsAccuracyLimitM;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('GPS 현장 정합 확인'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: currentPoint ?? kCourseRoute.points.first,
                initialZoom: 17.5,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.center_navigation',
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: kCourseRoute.points,
                      color: AppColors.teal,
                      strokeWidth: 5,
                    ),
                    if (currentPoint != null && projection != null)
                      Polyline(
                        points: [currentPoint, projection.closestPoint],
                        color: AppColors.red,
                        strokeWidth: 2,
                        isDotted: true,
                      ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    if (currentPoint != null)
                      Marker(
                        point: currentPoint,
                        width: 34,
                        height: 34,
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.blue,
                          size: 30,
                        ),
                      ),
                    if (projection != null)
                      Marker(
                        point: projection.closestPoint,
                        width: 22,
                        height: 22,
                        child: const Icon(
                          Icons.place,
                          color: Colors.red,
                          size: 22,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _gpsError ?? (current == null ? 'GPS 신호 대기 중…' : 'GPS 수신 중'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                if (current != null) ...[
                  Text(
                    '위도: ${current.latitude.toStringAsFixed(7)}  '
                    '경도: ${current.longitude.toStringAsFixed(7)}',
                  ),
                  Text(
                    'GPS 정확도: ${current.accuracy.toStringAsFixed(1)}m · '
                    '속도: ${(current.speed * 3.6).clamp(0, 300).toStringAsFixed(1)}km/h',
                  ),
                  Text(
                    '코스 이격 거리: ${projection!.offRouteDistanceMeters.toStringAsFixed(1)}m',
                    style: TextStyle(
                      color: !accuracyOk
                          ? Colors.orange
                          : projection.offRouteDistanceMeters >
                                  AppConfig.gpsOffRouteThresholdM
                              ? AppColors.red
                              : Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '코스 길이: ${kCourseRoute.totalKm.toStringAsFixed(3)}km · '
                  '기준점 ${kCourseRoute.points.length}개',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 4),
                const Text(
                  '이 화면은 OSM 지도와 실제 GPS 위치의 차이를 확인합니다. '
                  '기존 이미지 좌표 보정값은 변경하거나 저장하지 않습니다.',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: currentPoint == null
                        ? null
                        : () => _mapController.move(currentPoint, 18),
                    icon: const Icon(Icons.my_location),
                    label: const Text('현재 GPS 위치로 이동'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
