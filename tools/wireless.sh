#!/bin/bash
# 鸿蒙平板无线调试 / 推送工具
#
#   ./tools/wireless.sh connect            连接（自动发现设备 IP，必要时用 USB 开端口）
#   ./tools/wireless.sh connect 192.168.0.25   手动指定设备 IP
#   ./tools/wireless.sh status             查看连接状态
#   ./tools/wireless.sh build              编译并签名 HAP
#   ./tools/wireless.sh push               无线推送安装并启动
#   ./tools/wireless.sh push --build       编译 + 无线推送（常用）
#   ./tools/wireless.sh log                抓取应用相关日志（最近一屏）
#   ./tools/wireless.sh logf [关键字]      实时跟随日志（Ctrl+C 结束）
#   ./tools/wireless.sh shot [输出路径]    无线截图（默认 preview/wireless_shot.jpeg）
#   ./tools/wireless.sh shell "命令"       无线执行 shell 命令
#   ./tools/wireless.sh keepalive         每 15 秒心跳，保持 DevEco 里的无线设备不掉线
#   ./tools/wireless.sh enable             用 USB 开启设备 TCP 调试端口
#   ./tools/wireless.sh disable            关闭设备 TCP 调试端口（恢复纯 USB）
#
# 首次使用：插一次 USB 执行 `./tools/wireless.sh enable`，之后即可拔线。
# 设备 IP 记在 .wireless-device；换 Wi-Fi / 重启导致 IP 变化时，脚本会扫描局域网里
# 开放 8710 端口的主机自动找回，无需再插线（也可 connect <新IP> 手动指定）。
# 连接空闲会掉线，push/log/shot/shell 等命令都会自动重连；用 DevEco Studio 调试时
# 另开一个终端跑 keepalive 更稳。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
JBR="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
NODE_BIN="/Applications/DevEco-Studio.app/Contents/tools/node/bin"
HVIGOR="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"
SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
CACHE="$ROOT/.wireless-device"
PORT=8710
BUNDLE="com.example.helloworld"
ABILITY="EntryAbility"
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
KEY=""

usb_key() {
  "$HDC" list targets -v 2>/dev/null | awk '/USB/ && /Connected/ {print $1; exit}'
}

tcp_connected() {
  "$HDC" list targets -v 2>/dev/null | grep -q "^$1[[:space:]].*TCP[[:space:]]*Connected"
}

# 扫描局域网中开放 8710 端口的主机（IP 变化且没插线时自动找回设备）
scan_ip() {
  local localip base tmp ip
  localip="$(ipconfig getifaddr en0 2>/dev/null)"
  [ -z "$localip" ] && return 0
  base="$(printf '%s' "$localip" | cut -d. -f1-3)"
  for ip in $(arp -an 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p' \
      | grep "^$base\." | grep -v "^$localip$"); do
    if nc -z -G 1 "$ip" "$PORT" >/dev/null 2>&1; then
      printf '%s' "$ip"
      return 0
    fi
  done
  tmp="$(mktemp -t radio_scan)"
  seq 1 254 | xargs -P 40 -I{} \
    sh -c "nc -z -G 1 '$base.{}' '$PORT' >/dev/null 2>&1 && echo '$base.{}'" \
    > "$tmp" 2>/dev/null
  ip="$(head -1 "$tmp" | tr -d '[:space:]')"
  rm -f "$tmp"
  [ -n "$ip" ] && printf '%s' "$ip"
  return 0
}

# 找设备 IP：手动指定 → 缓存（且端口可达）→ USB 读 wlan0 → 局域网扫描
discover_ip() {
  local ip="${1:-}"
  if [ -n "$ip" ]; then
    printf '%s' "$ip"; return
  fi
  if [ -f "$CACHE" ]; then
    local cached
    cached="$(head -1 "$CACHE" | tr -d '[:space:]')"
    if [ -n "$cached" ] && nc -z -G 2 "$cached" "$PORT" >/dev/null 2>&1; then
      printf '%s' "$cached"; return
    fi
  fi
  local usb
  usb="$(usb_key)"
  if [ -n "$usb" ]; then
    ip="$("$HDC" -t "$usb" shell "ifconfig wlan0" 2>/dev/null \
      | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1 | tr -d '[:space:]')"
  fi
  if [ -z "$ip" ]; then
    ip="$(scan_ip)"
  fi
  if [ -z "$ip" ] && [ -f "$CACHE" ]; then
    ip="$(head -1 "$CACHE" | tr -d '[:space:]')"
  fi
  printf '%s' "$ip"
}

cmd_connect() {
  local ip
  ip="$(discover_ip "${1:-}")"
  if [ -z "$ip" ]; then
    echo "找不到设备：插一次 USB，或执行 $0 connect <设备IP>" >&2
    return 1
  fi
  printf '%s\n' "$ip" > "$CACHE"
  KEY="$ip:$PORT"
  if tcp_connected "$KEY"; then
    echo "已连接 $KEY"
    return 0
  fi
  # 设备刚重启 / 换网络时端口可能没开，趁 USB 还在线自动打开
  if ! nc -z -G 2 "$ip" "$PORT" >/dev/null 2>&1; then
    local usb
    usb="$(usb_key)"
    if [ -n "$usb" ]; then
      echo "正在用 USB 开启 TCP 调试端口 $PORT ..."
      "$HDC" -t "$usb" tmode port "$PORT" 2>&1 | head -2
      sleep 2
    else
      echo "端口 $PORT 未开放且 USB 不在线。请插一次 USB 后运行 $0 enable" >&2
      return 1
    fi
  fi
  "$HDC" tconn "$KEY" -remove >/dev/null 2>&1
  echo -n "连接 $KEY : "
  "$HDC" tconn "$KEY" 2>&1 | head -1
  tcp_connected "$KEY"
}

ensure() {
  local ip
  ip="$(discover_ip '')"
  [ -z "$ip" ] && { echo "找不到设备，先执行 $0 connect" >&2; return 1; }
  KEY="$ip:$PORT"
  if ! tcp_connected "$KEY"; then
    cmd_connect "$ip" >/dev/null || return 1
  fi
  return 0
}

cmd_status() {
  "$HDC" list targets -v 2>&1
  echo "--- 缓存 IP: $( [ -f "$CACHE" ] && cat "$CACHE" || echo '无') / 端口: $PORT ---"
  if ! "$HDC" list targets -v 2>/dev/null | grep -q "TCP.*Connected"; then
    echo "提示：会话空闲会掉线，运行 $0 connect 重连（push/log/shot 会自动重连）"
  fi
}

cmd_build() {
  local log rc
  log="$(mktemp -t radio_build)"
  echo "编译并签名 HAP ..."
  (cd "$ROOT" && DEVECO_SDK_HOME="$SDK_HOME" JAVA_HOME="$JBR" \
    PATH="$JBR/bin:$NODE_BIN:$PATH" \
    "$NODE_BIN/node" "$HVIGOR" assembleHap --mode module -p product=default \
    -p buildMode=debug --no-daemon) > "$log" 2>&1
  rc=$?
  # 过滤 hvigor log4js 关闭文件流时的无害噪音，只保留真实编译结果
  grep -iE "ERROR|BUILD SUCCESSFUL|BUILD FAILED|WARN: ArkTS" "$log" \
    | grep -viE "fileAppender|errorBuffer|ERR_STREAM_DESTROYED|write EPIPE" | tail -15
  if [ "$rc" -ne 0 ] || grep -q "BUILD FAILED" "$log"; then
    echo "编译失败，完整日志: $log" >&2
    return 1
  fi
  rm -f "$log"
  [ -f "$HAP" ] && echo "产物: $HAP"
}

cmd_push() {
  if [ "${1:-}" = "--build" ]; then
    cmd_build || return 1
  fi
  if [ ! -f "$HAP" ]; then
    echo "HAP 不存在，先执行 $0 build 或 $0 push --build" >&2
    return 1
  fi
  ensure || return 1
  echo "无线推送到 $KEY ..."
  "$HDC" -t "$KEY" install -r "$HAP" 2>&1 | tail -3
  echo -n "启动应用: "
  "$HDC" -t "$KEY" shell "aa start -a $ABILITY -b $BUNDLE" 2>&1 | head -2
}

cmd_log() {
  ensure || return 1
  "$HDC" -t "$KEY" shell "hilog -x" 2>/dev/null \
    | grep -iE "helloworld|ArkTS|JsError|Exception|crash" | tail -40
}

cmd_logf() {
  ensure || return 1
  local filter="${1:-}"
  echo "实时日志 $KEY （Ctrl+C 结束）"
  if [ -n "$filter" ]; then
    "$HDC" -t "$KEY" hilog 2>/dev/null | grep -i --line-buffered -- "$filter"
  else
    "$HDC" -t "$KEY" hilog 2>/dev/null
  fi
}

cmd_keepalive() {
  local ip
  ip="$(discover_ip '')"
  [ -z "$ip" ] && { echo "找不到设备，先执行 $0 connect" >&2; return 1; }
  KEY="$ip:$PORT"
  echo "保持 $KEY 在线（每 15 秒心跳，Ctrl+C 结束）"
  while true; do
    ensure >/dev/null 2>&1
    "$HDC" -t "$KEY" shell "param get const.product.model" >/dev/null 2>&1
    sleep 15
  done
}

cmd_shot() {
  ensure || return 1
  local out="${1:-$ROOT/preview/wireless_shot.jpeg}"
  "$HDC" -t "$KEY" shell "snapshot_display -f /data/local/tmp/wireless_shot.jpeg" >/dev/null 2>&1
  "$HDC" -t "$KEY" file recv /data/local/tmp/wireless_shot.jpeg "$out" 2>&1 | tail -1
  [ -f "$out" ] && echo "截图: $out"
}

cmd_shell() {
  [ -z "${1:-}" ] && { echo "用法: $0 shell \"命令\"" >&2; return 1; }
  ensure || return 1
  "$HDC" -t "$KEY" shell "$1" 2>&1
}

cmd_enable() {
  local usb
  usb="$(usb_key)"
  [ -z "$usb" ] && { echo "需要 USB 连接才能开启" >&2; return 1; }
  "$HDC" -t "$usb" tmode port "$PORT" 2>&1 | head -2
  sleep 2
  local ip
  ip="$("$HDC" -t "$usb" shell "ifconfig wlan0" 2>/dev/null \
    | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1 | tr -d '[:space:]')"
  [ -n "$ip" ] && printf '%s\n' "$ip" > "$CACHE"
  echo "设备 IP: $ip  端口: $PORT"
  cmd_connect "$ip"
}

cmd_disable() {
  # 关闭 TCP 会让无线会话立即断开，必须借 USB 执行，否则设备会失联
  local usb
  usb="$(usb_key)"
  if [ -z "$usb" ]; then
    echo "关闭 TCP 端口会切断无线连接，请先插上 USB 再执行 disable" >&2
    return 1
  fi
  "$HDC" -t "$usb" tmode port close 2>&1 | head -2
  echo "已关闭 TCP 调试端口（USB 调试仍可用）"
}

case "${1:-status}" in
  connect) shift; cmd_connect "${1:-}" ;;
  status)  cmd_status ;;
  build)   cmd_build ;;
  push)    shift; cmd_push "${1:-}" ;;
  log)     cmd_log ;;
  logf)    shift; cmd_logf "${1:-}" ;;
  shot)    shift; cmd_shot "${1:-}" ;;
  shell)   shift; cmd_shell "${1:-}" ;;
  keepalive) cmd_keepalive ;;
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  *) echo "未知命令: $1"; echo "用法见脚本头部注释"; exit 1 ;;
esac
