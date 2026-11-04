import 'package:flutter/material.dart';

class AppColors {
  AppColors._();
  static const primary = Color(0xFF35596E);
  static const primaryDeep = Color(0xFF2B4A5E);
  static const primaryLight = Color(0xFF437C8C);
  static const accent = Color(0xFF3B2FC9);
  static const bg = Color(0xFFF3F6F8);
  static const dark = Color(0xFF1F2A33);
  static const bus = Color(0xFFEF6C00);
  static const taxi = Color(0xFF2E7D32);
  static const teal = Color(0xFF00897B);
  static const purple = Color(0xFF6A4FC7);
  static const red = Color(0xFFE53935);
}

class AppConfig {
  AppConfig._();

  // ── 관리자 (보안 항목은 별도 논의) ──────────────────────────────
  static const String adminId = 'admin';
  static const String adminPassword = '1234';

  // ── 지도 ───────────────────────────────────────────────────────
  static const String mapAsset = 'assets/images/center_map.png';
  static const double mapWidthPx = 1103;
  static const double mapHeightPx = 1513;
  static const double mapAspectRatio = mapWidthPx / mapHeightPx;

  // ── 주행 시뮬레이션 ─────────────────────────────────────────────
  static const int tickMs = 500;
  static const double routeLengthKm = 1.298; // 2026-11-02 GPS 기록 기반 약 1.298km
  static const double maxSpeedKmh = 80;
  static const double speedLimitKmh = 40;
  static const double busCruiseKmh = 25;

  static const double steerStep = 0.015;
  static const double maxSteer = 0.06;

  // ── 이탈 / GPS 필터 ─────────────────────────────────────────────
  static const double offRouteThresholdM = 12;
  static const double offRouteConfirmSeconds = 3;
  static const double gpsOffRouteThresholdM = 18;
  static const double gpsSmoothing = 0.85; // GPS 원본 위치 반영 비율
  static const double gpsAccuracyLimitM = 40;
  static const double gpsMaxSpeedMps = 30;

  // ── 회전 감지 ───────────────────────────────────────────────────
  /// 이 각도 이상 꺾인 꼭짓점만 회전 안내 대상으로 삼는다.
  /// 기존 15°는 사소한 꺾임까지 잡았으므로 25°로 올렸다. 코스를 보며 조정할 것.
  static const double turnMinAngleDeg = 25;

  // ── 승객 호출 ───────────────────────────────────────────────────
  static const int callIntervalMinSec = 15;
  static const int callIntervalMaxSec = 25;
  static const int callAcceptWindowSec = 15;

  /// 현재 위치에서 호출 지점까지 허용하는 최소/최대 거리(km).
  static const double callMinKm = 0.2;
  static const double callMaxKm = 3.0;
  static const double pickupArrivalM = 30;
  static const double pickupPassM = 15;

  // ── 관제 서버 쓰기 ─────────────────────────────────────────────
  /// 차량 상태 노드를 이 시간(ms)마다 한 번은 강제로 쓴다.
  static const int fleetWriteIdleMs = 2000;

  /// 이 거리(m) 이상 움직였을 때 상태 노드를 쓴다.
  static const double fleetWriteMoveM = 3;

  /// 궤적(fleet_trail) 업로드 주기(초).
  static const int trailUploadSec = 10;

  // ── 궤적 / 평균속도 ─────────────────────────────────────────────
  /// 서버로 올리는 궤적의 최대 점 개수.
  static const int trailMaxPoints = 400;

  /// 궤적을 추가로 기록하는 최소 이동 거리(m).
  static const double trailMinStepM = 3.0;

  /// 평균속도를 계산하는 이동 창(초).
  static const int avgSpeedWindowSec = 30;
}
