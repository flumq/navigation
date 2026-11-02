"""
도면 이미지(center_map_cropped.png) → 벡터 데이터(lib/course_vector_data.dart) 변환
사용법:  python vectorize_map.py center_map_cropped.png lib/course_vector_data.dart
필요:    pip install numpy pillow scipy scikit-image
"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage import measure

SRC = sys.argv[1] if len(sys.argv) > 1 else "center_map_cropped.png"
OUT = sys.argv[2] if len(sys.argv) > 2 else "course_vector_data.dart"
TOL = 1.6          # 단순화 허용 오차(픽셀). 작을수록 정밀, 파일이 커짐
MIN_AREA = 60      # 이보다 작은 조각은 버림(픽셀)

img = np.array(Image.open(SRC).convert("RGB")).astype(int)
H, W, _ = img.shape
R, G, B = img[..., 0], img[..., 1], img[..., 2]

grass = (G - R > 8) & (G - B > 8)
road = (np.abs(R - G) < 8) & (np.abs(G - B) < 8) & (R > 150) & (R < 240)

def clean(mask):
    # 얇은 선(잡음) 제거 후 구멍 메우지 않음 (건물 구멍은 유지)
    m = ndi.binary_opening(mask, structure=np.ones((2, 2)))
    return m

def polygons(mask):
    out = []
    m = clean(mask).astype(float)
    for c in measure.find_contours(m, 0.5):
        if len(c) < 4:
            continue
        # find_contours 결과는 (row, col)
        area = 0.5 * abs(np.dot(c[:, 0], np.roll(c[:, 1], 1)) - np.dot(c[:, 1], np.roll(c[:, 0], 1)))
        if area < MIN_AREA:
            continue
        s = measure.approximate_polygon(c, tolerance=TOL)
        out.append(s)
    return out

def to_dart(name, polys, comment):
    lines = [f"// {comment}", f"const List<List<Offset>> {name} = ["]
    total = 0
    for p in polys:
        pts = [f"Offset({x / W:.4f}, {y / H:.4f})" for y, x in p]
        total += len(pts)
        lines.append("  [" + ", ".join(pts) + "],")
    lines.append("];")
    return "\n".join(lines), total

grass_polys = polygons(grass)
road_polys = polygons(road)

g_txt, gn = to_dart("kGrassPolygons", grass_polys, "잔디/녹지 영역 (정규화 0~1)")
r_txt, rn = to_dart("kRoadPolygons", road_polys, "도로 영역 (정규화 0~1)")

header = (
    "// 자동 생성 파일 - vectorize_map.py 로 만들었습니다. 직접 수정하지 마세요.\n"
    "// 좌표계: center_map_cropped.png 기준 0~1 상대좌표 (kCourseRoute, gpsToMap 과 동일)\n"
    "import 'dart:ui';\n\n"
)
with open(OUT, "w", encoding="utf-8") as f:
    f.write(header + g_txt + "\n\n" + r_txt + "\n")

print(f"grass polygons {len(grass_polys)} / points {gn}")
print(f"road polygons  {len(road_polys)} / points {rn}")
print(f"written: {OUT}")
