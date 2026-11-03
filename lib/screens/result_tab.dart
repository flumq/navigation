import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../core/geo.dart';
import '../map/map_layers.dart';
import '../models/course.dart';
import '../models/vehicle.dart';
import '../services/fleet_repository.dart';
import '../services/pickup_store.dart';
import '../widgets/common.dart';
import '../drive/telemetry.dart';

VehicleState? leaderOf(List<VehicleState> buses) {
  if (buses.isEmpty) return null;
  return buses.reduce((a, b) {
    if (a.laps != b.laps) return a.laps > b.laps ? a : b;
    return a.progress > b.progress ? a : b;
  });
}

class HeadwayPanel extends StatelessWidget {
  const HeadwayPanel({super.key, required this.buses, required this.leader});

  final List<VehicleState> buses;
  final VehicleState? leader;

  @override
  Widget build(BuildContext context) {
    final ldr = leader;
    if (ldr == null || buses.length < 2) {
      return AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Icon(Icons.route, size: 18, color: AppColors.bus),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '배차 간격: 버스가 2대 이상 접속하면 자동 계산됩니다.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ]),
      );
    }

    double gapOf(VehicleState f) =>
        forwardProgress(f.progress, ldr.progress) * AppConfig.routeLengthKm;

    final followers = buses.where((b) => b.id != ldr.id).toList()
      ..sort((a, b) => gapOf(a).compareTo(gapOf(b)));

    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.route, size: 18, color: AppColors.bus),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '참조 차량: ${ldr.id} (${ldr.laps}랩 완주 · 평균 ${ldr.avgSpeedKmh.toStringAsFixed(1)}km/h)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          for (final f in followers)
            Builder(builder: (_) {
              final gapKm = gapOf(f);
              final avg = headwaySpeedKmh(
                avgA: ldr.avgSpeedKmh,
                avgB: f.avgSpeedKmh,
                instA: ldr.speedKmh,
                instB: f.speedKmh,
              );
              final sec = (gapKm / avg * 3600).round();
              final mins = sec ~/ 60;
              final remSec = sec % 60;
              final color = mins < 3
                  ? AppColors.red
                  : (mins < 5 ? Colors.orange : Colors.green);
              final icon = mins < 3
                  ? Icons.warning_amber_rounded
                  : (mins < 5 ? Icons.info_outline : Icons.check_circle);

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      f.id,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text('${gapKm.toStringAsFixed(2)} km', style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 74,
                    child: Text(
                      '$mins분 ${remSec}초',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ),
                ]),
              );
            }),
        ],
      ),
    );
  }
}

class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              '차량 상태 범례',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            SizedBox(height: 8),
            _LegendItem(color: AppColors.taxi, label: '택시 · 정상'),
            _LegendItem(color: AppColors.bus, label: '버스 · 정상'),
            _LegendItem(color: AppColors.red, label: '경로 이탈'),
            _LegendItem(color: AppColors.teal, label: '코스 노선'),
            _LegendItem(color: Colors.orangeAccent, label: '1번 버스 참조 궤적'),
          ],
        ),
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      );
}

class ResultTab extends StatelessWidget {
  const ResultTab({
    super.key,
    required this.loggedIn,
    required this.onLoggedIn,
  });

  final bool loggedIn;
  final VoidCallback onLoggedIn;

  @override
  Widget build(BuildContext context) {
    if (!loggedIn) return _LoginGate(onLoggedIn: onLoggedIn);

    final fleet = FleetHub.current;
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) {
        final vehicles = fleet.vehicles.toList();
        final buses = vehicles.where((v) => v.type == VehicleType.bus).toList();
        final leader = leaderOf(buses);
        final offCount = vehicles.where((v) => v.isOffRoute).length;

        // 💡 MapView가 요구하는 레코드 타입 `({double lat, double lon})` 리스트로 올바르게 변환
        final routeCoords = kCourseRoute.points
            .map((p) => (lat: p.latitude, lon: p.longitude))
            .toList();

        final trailsList = <({List<LatLng> trail, Color color, double width})>[];
        if (leader != null && leader.trail.isNotEmpty) {
          trailsList.add((
            trail: leader.trail.map((tp) => LatLng(tp.lat, tp.lon)).toList(),
            color: Colors.orangeAccent,
            width: 5.0,
          ));
        }

        return Column(children: [
          AppHeader(
            title: '실시간 통합 관제',
            subtitle: '${vehicles.length}대 접속 · 버스 ${buses.length}대 · 이탈 $offCount대',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: HeadwayPanel(buses: buses, leader: leader),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: MapLegend(),
          ),
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  color: Colors.white,
                  child: MapView(
                    routePoints: routeCoords,
                    pickupPoints: PickupStore.instance.points,
                    vehicles: vehicles,
                    showScaleBar: true,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: vehicles.isEmpty
                ? const Center(
                    child: Text(
                      '현재 접속 중인 차량이 없습니다.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      for (final v in _sortedForList(vehicles))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: VehicleCard(state: v),
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
          ),
        ]);
      },
    );
  }
}

List<VehicleState> _sortedForList(List<VehicleState> vehicles) {
  return [...vehicles]..sort((a, b) {
      final oa = a.isOffRoute ? 0 : 1;
      final ob = b.isOffRoute ? 0 : 1;
      if (oa != ob) return oa.compareTo(ob);
      return a.id.compareTo(b.id);
    });
}

class _LoginGate extends StatelessWidget {
  const _LoginGate({required this.onLoggedIn});

  final VoidCallback onLoggedIn;

  @override
  Widget build(BuildContext context) => Column(children: [
        const AppHeader(
          title: '관제 결과',
          subtitle: '관리자 인증 후 실시간 관제를 볼 수 있습니다.',
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: GradientCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.admin_panel_settings,
                      color: Colors.white,
                      size: 56,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '관리자 전용 화면',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () async {
                          final ok = await showAdminLogin(context);
                          if (ok) onLoggedIn();
                        },
                        child: const Text(
                          '관리자 인증',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]);
}

class VehicleCard extends StatelessWidget {
  const VehicleCard({super.key, required this.state});

  final VehicleState state;

  @override
  Widget build(BuildContext context) {
    final isTaxi = state.type == VehicleType.taxi;
    final color = state.isOffRoute
        ? AppColors.red
        : (isTaxi ? AppColors.taxi : AppColors.bus);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(
            state.isOffRoute
                ? Icons.warning_rounded
                : (isTaxi ? Icons.local_taxi : Icons.directions_bus),
            color: color,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${state.id} (${state.type.name.toUpperCase()})',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '${state.location} · ${state.speedKmh.toStringAsFixed(1)} km/h · ${state.laps}랩',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        Text(
          state.status,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ]),
    );
  }
}