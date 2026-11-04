import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config.dart';
import '../models/pickup.dart';
import '../services/pickup_store.dart';
import '../widgets/common.dart';

/// 승하차 지점 종류에 따른 아이콘 반환 헬퍼
IconData pickupIcon(PickupKind kind) => switch (kind) {
      PickupKind.pickup => Icons.flight_takeoff,
      PickupKind.dropoff => Icons.flight_land,
      PickupKind.both => Icons.place,
    };

class PickupManagerSheet extends StatelessWidget {
  const PickupManagerSheet({super.key});

  Future<void> _showCode(BuildContext context) async {
    final code = PickupStore.instance.exportAsDartCode();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dart 코드로 내보내기'),
        content: SizedBox(
          width: 500,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('복사됨 · 소스에 붙여넣기')),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('복사'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListenableBuilder(
            listenable: PickupStore.instance,
            builder: (_, __) {
              final pts = PickupStore.instance.points;
              return Column(children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  const Text(
                    '승차 지점 관리',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _showCode(context),
                    icon: const Icon(Icons.code, size: 18),
                    label: const Text('코드로 내보내기'),
                  ),
                ]),
                const SizedBox(height: 8),
                Expanded(
                  child: pts.isEmpty
                      ? const Center(
                          child: Text(
                            '등록된 승차 지점이 없습니다.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView(
                          controller: scroll,
                          children: [
                            for (final p in pts)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: AppCard(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      pickupIcon(p.kind),
                                      color: AppColors.teal,
                                    ),
                                    title: Text(
                                      p.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${p.id} · ${(p.progress * 100).toStringAsFixed(1)}% · '
                                      '기본 ${p.baseFare}원 + ${p.perKmFare}원/km',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () =>
                                          PickupStore.instance.remove(p.id),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ]);
            },
          ),
        ),
      );
}
