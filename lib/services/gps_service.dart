import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/config.dart';

/// 사용 불가 사유를 문자열로 반환한다. null이면 정상.
Future<String?> ensureGpsReady() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    return '위치 서비스가 꺼져 있습니다';
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return '위치 권한이 없습니다';
  }
  return null;
}

/// 정확도 우선 GPS 스트림.
Stream<Position> gpsStream({int distanceFilter = 1}) =>
    Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
      ),
    );

class AveragedFix {
  const AveragedFix({required this.lat, required this.lon, required this.acc});

  final double lat, lon, acc;
}

/// 정확도 기준을 통과한 샘플 [want]개의 평균.
/// [timeout]이 지나면 모인 만큼으로 계산하고, 하나도 없으면 null을 반환한다.
Future<AveragedFix?> averageFix({
  int want = 5,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final samples = <Position>[];
  final done = Completer<void>();
  final sub = gpsStream(distanceFilter: 0).listen((p) {
    if (p.accuracy <= AppConfig.gpsAccuracyLimitM) {
      samples.add(p);
      if (samples.length >= want && !done.isCompleted) done.complete();
    }
  });
  try {
    await done.future.timeout(timeout);
  } catch (_) {
    // 시간 초과 시 지금까지 모인 샘플로 계산한다.
  }
  await sub.cancel();
  if (samples.isEmpty) return null;

  double avg(double Function(Position) f) =>
      samples.map(f).reduce((a, b) => a + b) / samples.length;

  return AveragedFix(
    lat: avg((p) => p.latitude),
    lon: avg((p) => p.longitude),
    acc: avg((p) => p.accuracy),
  );
}