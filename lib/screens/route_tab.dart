import 'package:flutter/material.dart';

import '../map/map_layers.dart';
import '../models/course.dart';
import '../services/fleet_repository.dart';
import '../services/pickup_store.dart';
import '../widgets/common.dart';

class RouteTab extends StatelessWidget {
  const RouteTab({super.key});

  @override
  Widget build(BuildContext context) {
    final fleet = FleetHub.current;
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) {
        final routeCoords = kCourseRoute.points
            .map((p) => (lat: p.latitude, lon: p.longitude))
            .toList();

        return Column(children: [
          const AppHeader(
            title: '코스 경로',
            subtitle: '코스 노선과 픽업 지점을 확인합니다.',
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  color: Colors.white,
                  child: MapView(
                    routePoints: routeCoords,
                    pickupPoints: PickupStore.instance.points,
                    vehicles: fleet.vehicles.toList(),
                    showScaleBar: true,
                  ),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
