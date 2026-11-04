import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'core/config.dart';
import 'firebase_options.dart';
import 'screens/home_tab.dart';
import 'screens/measure_tab.dart';
import 'screens/result_tab.dart';
import 'screens/route_tab.dart';
import 'services/fleet_repository.dart';
import 'services/pickup_store.dart';
import 'services/voice_announcer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FleetHub.firebaseReady = true;
  } catch (e) {
    debugPrint('Firebase 초기화 실패, 오프라인 모드로 실행: $e');
  }

  await PickupStore.instance.load();
  await NavAnnouncer.instance.init();

  runApp(const CenterTrainingApp());
}

// =============================================================================
// 앱 루트
// =============================================================================
class CenterTrainingApp extends StatelessWidget {
  const CenterTrainingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TS 스마트 통합 관제 시스템',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary),
          scaffoldBackgroundColor: AppColors.bg,
        ),
        home: const MainShell(),
      );
}

// =============================================================================
// 하단 탭 셸
// =============================================================================
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  bool _adminOk = false;

  void _goTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            HomeTab(onNavigate: _goTo),
            const MeasureTab(),
            const RouteTab(),
            ResultTab(
              loggedIn: _adminOk,
              onLoggedIn: () => setState(() => _adminOk = true),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _goTo,
          indicatorColor: AppColors.primary.withValues(alpha: 0.15),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: '시작'),
            NavigationDestination(
                icon: Icon(Icons.sensors_outlined),
                selectedIcon: Icon(Icons.sensors),
                label: '측정'),
            NavigationDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map),
                label: '경로'),
            NavigationDestination(
                icon: Icon(Icons.bar_chart_outlined),
                selectedIcon: Icon(Icons.bar_chart),
                label: '결과'),
          ],
        ),
      );
}
