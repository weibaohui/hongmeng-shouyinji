#!/usr/bin/env python3
"""生成平板版收音机的应用图标（沿用 E6 版黄色复古收音机的意象，重绘为高清分层图标）。"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
MEDIA = ROOT / 'entry/src/main/resources/base/media'
APPSCOPE = ROOT / 'AppScope/resources/base/media'
S = 1024  # 超采样，最后缩到目标尺寸


def rr(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def render(size: int, transparent: bool = False) -> Image.Image:
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0) if transparent else (0, 0, 0, 255))
    d = ImageDraw.Draw(im)
    if not transparent:
        # 深色渐变底（竖向三层近似）
        for y in range(S):
            t = y / S
            col = (int(16 + 7 * t), int(26 + 11 * t), int(40 + 16 * t), 255)
            d.line([(0, y), (S, y)], fill=col)
    # 大圆角底板
    rr(d, (40, 40, S - 40, S - 40), 210, (18, 28, 42, 255))
    # 电波弧线
    for i, alpha in enumerate((70, 110, 150)):
        box = (520 + i * 78, 100 + i * 78, 980 - i * 10, 560 - i * 10)
        d.arc(box, start=255, end=340, fill=(76, 154, 255, alpha), width=18)
    # 天线
    d.line([(755, 300), (870, 175)], fill=(230, 238, 248, 255), width=20)
    d.ellipse((852, 157, 892, 197), fill=(246, 195, 68, 255))
    # 收音机机身
    rr(d, (120, 330, 900, 790), 96, (246, 195, 68, 255))
    rr(d, (150, 360, 870, 760), 72, (255, 210, 92, 255))
    # 扬声器
    d.ellipse((196, 420, 536, 720), fill=(26, 38, 56, 255))
    import math
    cx, cy, radius = 366, 570, 148
    for y in range(452, 700, 34):
        half = math.sqrt(max(0, radius * radius - (y - cy) ** 2)) - 4
        d.line([(cx - half, y), (cx + half, y)], fill=(56, 82, 116, 255), width=12)
    # 调谐显示屏
    rr(d, (588, 430, 820, 566), 26, (28, 52, 82, 255))
    rr(d, (606, 448, 802, 548), 16, (76, 154, 255, 255))
    d.line([(628, 498), (778, 498)], fill=(226, 240, 255, 255), width=8)
    d.polygon([(700, 466), (688, 486), (712, 486)], fill=(255, 255, 255, 255))
    # 旋钮
    d.ellipse((590, 606, 686, 702), fill=(26, 38, 56, 255))
    d.ellipse((608, 624, 668, 684), fill=(76, 154, 255, 255))
    d.ellipse((724, 628, 804, 708), fill=(224, 120, 72, 255))
    return im.resize((size, size), Image.LANCZOS)


for size, name in ((512, 'app_icon.png'), (192, 'icon.png'), (128, 'startIcon.png')):
    render(size).save(APPSCOPE / name if name == 'app_icon.png' else MEDIA / name)
render(512).save(MEDIA / 'app_icon.png')
print('[*] 图标已生成:', APPSCOPE, MEDIA)
