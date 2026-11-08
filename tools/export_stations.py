#!/usr/bin/env python3
"""把 E6 收音机的 radio.db 导出为 HarmonyOS ArkTS 静态数据模块。

用法：
  python3 tools/export_stations.py [radio.db 路径]
  RADIO_DB=/path/to/radio.db python3 tools/export_stations.py

产物：
  entry/src/main/ets/model/data/StationDataPart{1..4}.ets  分片数据
  entry/src/main/ets/model/StationData.ets                 汇总入口
  preview/stations.js                                     HTML 预览用数据

数据来源：youdao-tinglibao-e6/framework/examples/radio/assets/radio.db
"""
import json
import os
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# 数据来源可用命令行参数、环境变量或工程内 assets/radio.db 指定，不硬编码个人目录。
CANDIDATE_DBS = (
    os.environ.get('RADIO_DB', ''),
    ROOT / 'assets/radio.db',
    Path.home() / 'Desktop/youdao-tinglibao-e6/framework/examples/radio/assets/radio.db',
)
DEFAULT_DB = next((Path(p) for p in CANDIDATE_DBS if p and Path(p).exists()),
                  ROOT / 'assets/radio.db')
OUT_DIR = ROOT / 'entry/src/main/ets/model/data'
PARTS = 4

HEADER = """// 由 tools/export_stations.py 从 radio.db 自动生成，请勿手工修改。
// 数据来自 youdao-tinglibao-e6 收音机示例（蜻蜓 FM / Radio Browser 公开流）。
import { Station } from '../Station';

export const STATION_PART_%d: Station[] = [
"""


def esc(value: object) -> str:
    return json.dumps('' if value is None else str(value), ensure_ascii=False)


# 已验证支持 TLS 的 http 域名：优先用 https，减少真机上被明文策略拦截的概率。
# 其余 http 流保持原样，运行时播放器会在失败时自动尝试切换协议重试。
HTTPS_READY_HOSTS = ('lhttp.qingting.fm', 'lhttp.qtfm.cn')


def normalize_url(url: str) -> str:
    if url.startswith('http://'):
        host = url[7:].split('/')[0].split(':')[0]
        if host in HTTPS_READY_HOSTS:
            return 'https://' + url[7:]
    return url


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.exists():
        raise SystemExit('找不到 radio.db：请用参数指定路径，或设置环境变量 RADIO_DB')
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        'SELECT id, name, url, province, city, genre, country, country_code '
        'FROM stations WHERE status = 1 ORDER BY id ASC'
    ).fetchall()
    conn.close()

    stations = []
    for r in rows:
        url = (r['url'] or '').strip()
        if not url.startswith(('http://', 'https://')):
            continue
        code = (r['country_code'] or 'CN').strip()
        stations.append({
            'id': int(r['id']),
            'name': (r['name'] or '').strip(),
            'url': normalize_url(url),
            'province': (r['province'] or '').strip(),
            'city': (r['city'] or '').strip(),
            'genre': (r['genre'] or '综合').strip(),
            'country': (r['country'] or '中国').strip(),
            'countryCode': code,
        })

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    chunk = (len(stations) + PARTS - 1) // PARTS
    for i in range(PARTS):
        part = stations[i * chunk:(i + 1) * chunk]
        lines = [HEADER % (i + 1)]
        for s in part:
            lines.append(
                '  { id: %d, name: %s, url: %s, province: %s, city: %s, genre: %s, country: %s, countryCode: %s },\n'
                % (s['id'], esc(s['name']), esc(s['url']), esc(s['province']),
                   esc(s['city']), esc(s['genre']), esc(s['country']), esc(s['countryCode']))
            )
        lines.append('];\n')
        (OUT_DIR / ('StationDataPart%d.ets' % (i + 1))).write_text(''.join(lines), encoding='utf-8')

    imports = '\n'.join("import { STATION_PART_%d } from './data/StationDataPart%d';" % (i, i)
                        for i in range(1, PARTS + 1))
    concat = ('STATION_PART_1' +
              ''.join('\n  .concat(STATION_PART_%d)' % i for i in range(2, PARTS + 1)))
    summary = (
        '// 由 tools/export_stations.py 生成：%d 个电台，静态编译进 HAP，无需运行时联网取列表。\n'
        "import { Station } from './Station';\n"
        '%s\n\n'
        'export const ALL_STATIONS: Station[] = %s;\n'
    ) % (len(stations), imports, concat)
    (ROOT / 'entry/src/main/ets/model/StationData.ets').write_text(summary, encoding='utf-8')

    (ROOT / 'preview/stations.js').write_text(
        '// 由 tools/export_stations.py 生成，仅供 HTML 界面预览使用\n'
        'window.RADIO_STATIONS = ' + json.dumps(stations, ensure_ascii=False) + ';\n',
        encoding='utf-8')

    cn = sum(1 for s in stations if s['countryCode'] == 'CN')
    print('[*] 导出电台 %d 台（国内 %d / 国际 %d），分 %d 个 ArkTS 分片'
          % (len(stations), cn, len(stations) - cn, PARTS))
    print('[*] 输出目录: %s' % OUT_DIR)


if __name__ == '__main__':
    main()
