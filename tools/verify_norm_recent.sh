#!/bin/bash
# 音量归一化 + 最近播放 验证脚本
#
# 用法：设备解锁后运行
#   bash tools/verify_norm_recent.sh
#
# 前置：平板已解锁（锁屏状态下 aa start 会被系统拒绝），应用已安装。

set -u
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
DEV="${E6_DEVICE:-62BBB25C10200765}"
T="$HDC -t $DEV"
PKG="com.example.helloworld"
SHOT=/tmp/vr_shot.jpeg

echo "=== 0. 设备与启动 ==="
$T shell "power-shell timeout -o 1800000" >/dev/null 2>&1
$T shell "power-shell wakeup" >/dev/null 2>&1
$T shell "aa force-stop $PKG" >/dev/null 2>&1
OUT=$($T shell "aa start -a EntryAbility -b $PKG" 2>&1 | head -1)
echo "    start -> $OUT"
if echo "$OUT" | grep -q "failed to start"; then
  echo "    !! 启动失败，多半是屏幕还锁着。解锁后重跑。"
  exit 1
fi
sleep 4
PID=$($T shell "pidof $PKG" 2>&1 | tr -d '\r\n ')
echo "    pid = $PID"

shot() { # shot <输出文件>
  $T shell "snapshot_display -f /data/local/tmp/vr.jpeg" >/dev/null 2>&1
  $T file recv /data/local/tmp/vr.jpeg "$1" >/dev/null 2>&1
}

echo
echo "=== 1. 归一化：确认 setLoudnessGain 在本机可用 ==="
$T shell "hilog -r" >/dev/null 2>&1
sleep 1

echo "=== 2. 播放一个电台，等待测量完成（约 15 秒）==="
# 播放按钮坐标（2560x1600）
$T shell "uitest uiInput click 1940 1020" >/dev/null 2>&1
sleep 18

echo "--- RadioPlayer 日志（loudness 是否 applied）---"
$T shell "hilog -x -T RadioPlayer" 2>&1 | tail -12

echo "--- 归一化状态（normGain / 提示文案）---"
$T shell "uitest dumpLayout" >/dev/null 2>&1
F=$($T shell "ls -t /data/local/tmp/layout_*.json | head -1" | tr -d '\r')
$T file recv "$F" /tmp/vr_layout.json >/dev/null 2>&1
python3 - <<'PY'
import json
d=json.load(open('/tmp/vr_layout.json'))
hits=[]
def walk(n):
    a=n.get('attributes',{})
    t=a.get('text','')
    if t and any(k in t for k in ('归一化','测量','最近播放','正在测量','已归一化','收听记录')):
        hits.append(t)
    for c in n.get('children',[]): walk(c)
walk(d)
for h in hits[:20]: print('   ', h)
if not hits: print('    (界面上没找到归一化相关文案)')
PY

echo
echo "=== 3. 最近播放：切几台再回看 ==="
$T shell "uitest uiInput click 2140 1021" >/dev/null 2>&1   # 下一台
sleep 6
$T shell "uitest uiInput click 2140 1021" >/dev/null 2>&1
sleep 6
shot $SHOT
echo "    截图: $SHOT"

echo
echo "=== 4. 总结要看的东西 ==="
cat <<'EOF'
  a) RadioPlayer 日志里出现 "loudness <n> dB applied"  → 系统响度增益可用，归一化走系统链路
     出现 "loudness unsupported" + "fall back to volume scaling" → 已自动降级为音量缩放
  b) 设置面板「音量归一化」下面出现 "本台已归一化 ±X.XdB" → 测量出结果并已生效
  c) 播放页台名下方出现 "· 归一化 ±X.XdB" → 修正值可见
  d) 左侧导航出现「最近播放」及条数，列表里有"刚刚 / N 分钟前"
EOF
