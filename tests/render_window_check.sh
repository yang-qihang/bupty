#!/usr/bin/env bash
# tests/render_window_check.sh —— 多窗口尺寸渲染自检（文本快照 + 溢出断言）。
# 在多种 COLUMNS/LINES 下渲染各视图，检查：帧行数不超过 UI_ROWS（页眉不被顶出）、
# 任意行显示宽度不超过 UI_COLS（无横向越界换行）、页眉存在。
#
# 用法：bash tests/render_window_check.sh
# 依赖：真实 fixture / 或调用方预先填充视图数据（见下方 _setup_data）。
# 本脚本只做「已加载数据」的渲染自检；未登录/未加载态由 tests/snapshot.sh 覆盖。
# 任一检查失败以非零退出码报告，便于作为回归门槛。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUPTY_NO_COLOR=1
export XDG_CONFIG_HOME="$(mktemp -d)"
mkdir -p "${XDG_CONFIG_HOME}/bupty"
printf '{"account":"2025211681","password":"x"}' > "${XDG_CONFIG_HOME}/bupty/credentials.json"
chmod 600 "${XDG_CONFIG_HOME}/bupty/credentials.json"

# shellcheck disable=SC1090
source "${BUPTY_HOME}/tui.sh"

# 用 fixture 填充视图数据（离线确定性）。真实课表/空教室 fixture 若存在则用之。
_setup_data() {
  if [[ -f "${BUPTY_HOME}/tests/fixtures/schedule.json" ]]; then
    SCHEDULE_DATA="$(cat "${BUPTY_HOME}/tests/fixtures/schedule.json")"
    SCHEDULE_ACCOUNT="2025211681"; SCHEDULE_LOADED=1
  fi
  if [[ -f "${BUPTY_HOME}/tests/fixtures/classrooms.json" ]]; then
    CLASSROOMS_DATA="$(cat "${BUPTY_HOME}/tests/fixtures/classrooms.json")"
    CLASSROOMS_ACCOUNT="2025211681"; CLASSROOMS_LOADED=1
  fi
  if [[ -f "${BUPTY_HOME}/tests/fixtures/booking-roommenu.json" ]]; then
    BOOKING_CATEGORIES="$(_booking_parse_categories "$(cat "${BUPTY_HOME}/tests/fixtures/booking-roommenu.json")")"
    BOOKING_ACCOUNT="2025211681"; BOOKING_LOADED=1
    BOOKING_TAB=0
    BOOKING_DEPTH=0
  fi
}

# 显示宽度：盒线字符按 1 列、CJK/全角按 2 列、其余按 1 列。
# 与 lib/core.sh 的 _core_width 一致，但把盒线（U+2500–U+257F）计为 1 列，
# 因为分隔线按 UI_COLS 个盒线字符绘制（每个占 1 列），不应被误判为超宽。
_width() {
  local s="$1" w=0 i ch cp
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    printf -v cp '%d' "'${ch}"
    if (( cp >= 0x2500 && cp <= 0x257F )); then
      w=$((w + 1))
    elif (( cp > 255 )); then
      w=$((w + 2))
    else
      w=$((w + 1))
    fi
  done
  printf '%s' "${w}"
}

FAIL=0

# 渲染一帧并做检查。参数：view cols rows
_check_view() {
  local view="$1" cols="$2" rows="$3"
  TUI_VIEW="$view"; UI_COLS=$cols; UI_ROWS=$rows
  local out nlines maxw first line w
  out="$( { TUI_FRAME_FILE="$(mktemp)"; tui_render; rm -f "${TUI_FRAME_FILE}"; } 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*[A-Z]//g' )"
  nlines="$(printf '%s' "${out}" | wc -l)"
  maxw=0
  while IFS= read -r line; do
    w="$(_width "${line}")"
    (( w > maxw )) && maxw=$w
  done <<< "${out}"
  local overflow="" header="" wide=""
  (( nlines > rows )) && overflow="溢出"
  printf '%s' "${out}" | grep -q 'bupty' || header="缺页眉"
  (( maxw > cols )) && wide="超宽"
  if [[ -n "${overflow}${header}${wide}" ]]; then
    FAIL=1
  fi
  printf '  %-12s %3sx%-3s 行=%-3s 宽max=%-4s %s\n' "${view}" "${cols}" "${rows}" "${nlines}" "${maxw}" "${overflow:-} ${header:-} ${wide:-}"
}

ui_theme_init
ui_box_init
_setup_data
_schedule_precompute 2>/dev/null || true
_classrooms_precompute 2>/dev/null || true

echo "== 多窗口尺寸渲染自检 =="
for sz in "80 24" "100 30" "120 40" "60 20" "140 50"; do
  set -- $sz
  echo "-- ${1}x${2} --"
  for v in home schedule classrooms public booking; do
    _check_view "$v" "$1" "$2"
  done
done

rm -rf "${XDG_CONFIG_HOME}"
if (( FAIL )); then
  echo "存在渲染缺陷（见上表“溢出 / 缺页眉 / 超宽”）。"
  exit 1
fi
echo "全部窗口尺寸渲染正常。"
