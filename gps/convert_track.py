import json
import math
import numpy as np

# ===== 설정 =====
TRACK_FILE = "track.json"
SIMPLIFY_EPS = 0.002  # 노선 단순화 허용 오차 (지도 폭 대비). 작을수록 점이 많아짐

# (위도, 경도, 이미지 x 비율, 이미지 y 비율)  ← 실제로 측정한 값으로 교체
LANDMARKS = [
    (37.2801, 127.0432, 0.20, 0.80),
    (37.2815, 127.0450, 0.55, 0.35),
    (37.2790, 127.0460, 0.80, 0.70),
]


def load_track(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        for key in ("points", "track", "locations", "data"):
            if key in data:
                data = data[key]
                break
    pts = []
    for p in data:
        lat = p.get("lat", p.get("latitude"))
        lng = p.get("lng", p.get("lon", p.get("longitude")))
        if lat is None or lng is None:
            continue
        pts.append((float(lat), float(lng)))
    return pts


def haversine_km(a, b):
    r = 6371.0
    la1, lo1 = map(math.radians, a)
    la2, lo2 = map(math.radians, b)
    h = (math.sin((la2 - la1) / 2) ** 2
         + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(h))


def route_length_km(pts):
    return sum(haversine_km(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def rdp(points, eps):
    """Ramer-Douglas-Peucker 단순화"""
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    max_d, idx = 0.0, 0
    for i in range(1, len(points) - 1):
        x, y = points[i]
        seg_len_sq = dx * dx + dy * dy
        if seg_len_sq == 0:
            d = math.hypot(x - x1, y - y1)
        else:
            t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / seg_len_sq))
            d = math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))
        if d > max_d:
            max_d, idx = d, i
    if max_d > eps:
        left = rdp(points[: idx + 1], eps)
        right = rdp(points[idx:], eps)
        return left[:-1] + right
    return [points[0], points[-1]]


def main():
    # 1) 변환식 계산 (위도/경도 → 이미지 0~1 좌표), 최소제곱법 아핀 변환
    src = np.array([[la, lo, 1.0] for la, lo, _, _ in LANDMARKS])
    dst = np.array([[u, v] for _, _, u, v in LANDMARKS])
    M, *_ = np.linalg.lstsq(src, dst, rcond=None)

    residual = np.sqrt(((src @ M - dst) ** 2).sum(axis=1))
    print(f"기준점 오차(이미지 비율): {np.round(residual, 4)}")
    if residual.max() > 0.01:
        print("⚠️ 기준점 오차가 큽니다. 기준점 위치나 측정값을 다시 확인하세요.\n")

    # 2) 주행 기록을 이미지 좌표로 변환
    track = load_track(TRACK_FILE)
    tp = np.array([[la, lo, 1.0] for la, lo in track])
    norm = tp @ M
    if ((norm < -0.02) | (norm > 1.02)).any():
        print("⚠️ 일부 좌표가 지도 밖에 있습니다. 기준점이나 지도 파일을 확인하세요.")

    pts = [(float(u), float(v)) for u, v in norm]

    # 3) 노선 단순화
    simplified = rdp(pts, SIMPLIFY_EPS)

    # 4) 실제 노선 길이
    km = route_length_km(track)

    print(f"원본 점 수: {len(pts)}, 단순화 후: {len(simplified)}")
    print(f"실제 노선 길이: {km:.2f} km\n")

    print("// ===== main.dart의 kCourseRoute에 붙여넣기 =====")
    print("final RouteGeometry kCourseRoute = RouteGeometry(const [")
    for u, v in simplified:
        print(f"  Offset({u:.4f}, {v:.4f}),")
    print("]);")
    print(f"\n// AppConfig.routeLengthKm = {km:.2f};")


if __name__ == "__main__":
    main()