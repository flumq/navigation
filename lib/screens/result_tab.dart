import 'package:flutter/material.dart';

import '../core/config.dart';
import '../map/map_layers.dart';
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          const Icon(Icons.route, size: 16, color: AppColors.bus),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '배차 간격: 버스가 2대 이상 접속하면 자동 계산됩니다.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ]),
      );
    }

    double gapOf(VehicleState f) {
  final d = (ldr.progress - f.progress) % 1.0;
  final forward = d < 0 ? d + 1.0 : d;
  return forward * AppConfig.routeLengthKm;
}
    final followers = buses.where((b) => b.id != ldr.id).toList()
      ..sort((a, b) => gapOf(a).compareTo(gapOf(b)));

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.route, size: 16, color: AppColors.bus),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '기준 차량: ${ldr.id} (${ldr.laps}랩 완주)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ]),
          const SizedBox(height: 4),
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

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      '후속 ${f.id}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text('${gapKm.toStringAsFixed(2)} km', style: const TextStyle(fontSize: 11)),
                  const SizedBox(width: 10),
                  Text(
                    '$mins분 $remSec초 간격',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: color,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: const [
            _LegendItem(color: AppColors.taxi, label: '택시'),
            _LegendItem(color: AppColors.bus, label: '버스'),
            _LegendItem(color: AppColors.red, label: '이탈'),
          ],
        ),
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);
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

        // 초록색 코스 노선 선 제거
        final List<({double lat, double lon})> routeCoords = [];

        return Column(children: [
          AppHeader(
            title: '실시간 통합 관제',
            subtitle: '${vehicles.length}대 접속 · 버스 ${buses.length}대 · 이탈 $offCount대',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: HeadwayPanel(buses: buses, leader: leader),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: MapLegend(),
          ),
          // 지도 영역 크기를 더욱 크게 확대 (flex: 10)
          Expanded(
            flex: 10,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
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
          // 하단 차량 목록 영역
          Expanded(
            flex: 2,
            child: vehicles.isEmpty
                ? const Center(
                    child: Text(
                      '현재 접속 중인 차량이 없습니다.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (final v in _sortedForList(vehicles))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: VehicleCard(state: v),
                        ),
                      const SizedBox(height: 16),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(
            state.isOffRoute
                ? Icons.warning_rounded
                : (isTaxi ? Icons.local_taxi : Icons.directions_bus),
            color: color,
            size: 18,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${state.id} (${state.type.name.toUpperCase()})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                '${state.location} · ${state.speedKmh.toStringAsFixed(1)} km/h · ${state.laps}랩',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        Text(
          state.status,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 11,
          ),
        ),
      ]),
    );
  }
}