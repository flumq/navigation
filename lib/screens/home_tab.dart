import 'package:flutter/material.dart';

import '../core/config.dart';
import '../models/vehicle.dart';
import '../services/fleet_repository.dart';
import '../widgets/common.dart';
import 'bus_dashboard_screen.dart';
import 'taxi_navi_screen.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final _idController = TextEditingController();

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _start(VehicleType type) {
    final id = _idController.text.trim();
    if (id.isEmpty) {
      _toast('교육생 ID를 입력해주세요.');
      return;
    }
    if (FleetHub.current.isActive(id)) {
      _toast('$id 은(는) 이미 접속 중입니다.');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => type == VehicleType.bus
            ? BusDashboardScreen(driverId: id)
            : TaxiNaviScreen(studentId: id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.zero,
        children: [
          const AppHeader(
            title: '운전행동분석',
            subtitle: '교육생 ID를 입력하고 교육 과정을 선택하세요.',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: GradientCard(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '교육 세션',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '교육생을 확인한 뒤\n이번 운행을 시작하세요',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TextField(
                      controller: _idController,
                      decoration: const InputDecoration(
                        hintText: '예: 택시01, 버스01',
                        prefixIcon: Icon(Icons.badge_outlined),
                        border: InputBorder.none,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                      child: LightButton(
                        icon: Icons.directions_bus,
                        label: '버스 교육',
                        onTap: () => _start(VehicleType.bus),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: LightButton(
                        icon: Icons.local_taxi,
                        label: '택시 교육',
                        onTap: () => _start(VehicleType.taxi),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          const SectionTitle('빠른 실행'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 1.25,
              children: [
                QuickTile(
                  icon: Icons.directions_bus,
                  label: '버스 교육',
                  color: AppColors.bus,
                  onTap: () => _start(VehicleType.bus),
                ),
                QuickTile(
                  icon: Icons.local_taxi,
                  label: '택시 교육',
                  color: AppColors.taxi,
                  onTap: () => _start(VehicleType.taxi),
                ),
                QuickTile(
                  icon: Icons.sensors,
                  label: 'GPS 기록',
                  color: AppColors.teal,
                  onTap: () => widget.onNavigate(1),
                ),
                QuickTile(
                  icon: Icons.map_outlined,
                  label: '경로 보정',
                  color: Colors.orange,
                  onTap: () => widget.onNavigate(2),
                ),
                QuickTile(
                  icon: Icons.bar_chart,
                  label: '관제 결과',
                  color: AppColors.purple,
                  onTap: () => widget.onNavigate(3),
                ),
                QuickTile(
                  icon: Icons.admin_panel_settings_outlined,
                  label: '관리자 인증',
                  color: AppColors.accent,
                  onTap: () => widget.onNavigate(3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      );
}