import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';
import '../models/course.dart';
import '../models/pickup.dart';
import '../models/vehicle.dart';

/// 전역 공용 지도 뷰어 위젯 (ResultTab, RouteTab 등에서 공용으로 사용)
class MapView extends StatelessWidget {
  const MapView({
    super.key,
    required this.routePoints,
    this.vehicles = const [],
    this.pickupPoints = const [],
    this.trails = const [],
    this.livePosition,
    this.showScaleBar = false,
    this.onTapLatLng,
  });

  final List<({double lat, double lon})> routePoints;
  final List<VehicleState> vehicles;
  final List<PickupPoint> pickupPoints;
  final List<({List<LatLng> trail, Color color, double width})> trails;
  final ({double lat, double lon})? livePosition;
  final bool showScaleBar;
  final void Function(LatLng latLng)? onTapLatLng;

  @override
  Widget build(BuildContext context) {
    final latLngRoute = routePoints.map((p) => LatLng(p.lat, p.lon)).toList();
    final initialCenter = latLngRoute.isNotEmpty ? latLngRoute.first : const LatLng(37.2315, 126.7795);

    return FlutterMap(
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: 17.0,
        onTap: (tapPosition, latLng) {
          onTapLatLng?.call(latLng);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.center_navigation',
        ),
        if (latLngRoute.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: latLngRoute,
                color: AppColors.teal,
                strokeWidth: 4.0,
              ),
              for (final t in trails)
                Polyline(
                  points: t.trail,
                  color: t.color,
                  strokeWidth: t.width,
                ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (final p in pickupPoints)
              Marker(
                point: p.latLng,
                width: 30,
                height: 30,
                child: Container(
                  decoration: BoxDecoration(
                    color: p.kind == PickupKind.pickup ? Colors.blue : Colors.orange,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.place, size: 16, color: Colors.white),
                ),
              ),
            for (final v in vehicles)
              Marker(
                point: v.position,
                width: 36,
                height: 36,
                child: Container(
                  decoration: BoxDecoration(
                    color: v.type == VehicleType.taxi ? AppColors.taxi : AppColors.bus,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Icon(
                    v.type == VehicleType.taxi ? Icons.local_taxi : Icons.directions_bus,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            if (livePosition != null)
              Marker(
                point: LatLng(livePosition!.lat, livePosition!.lon),
                width: 32,
                height: 32,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.blueAccent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.my_location, color: Colors.white, size: 16),
                ),
              ),
          ],
        ),
      ],
    );
  }
}