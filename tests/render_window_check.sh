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
printf '{"account":"2025000000","password":"x"}' > "${XDG_CONFIG_HOME}/bupty/credentials.json"
chmod 600 "${XDG_CONFIG_HOME}/bupty/credentials.json"

# shellcheck disable=SC1090
source "${BUPTY_HOME}/tui.sh"

# 宽度口径是「UTF-8 码点 → 显示列」，依赖 locale 正确。非 UTF-8 时 bash 的
# ${s:i:1} 按**字节**切，一个 3 字节的汉字会被切成 3 个「字符」逐个计列 → 宽度虚高，
# 整表会假报「超宽」。与其给假结论，不如明确报错退出（也可用 BUPTY_FORCE_UTF8=1
# 强制按 UTF-8 口径量，用于无 UTF-8 locale 的 CI）。
if ! core_utf8; then
  printf 'render_window_check: 需要 UTF-8 locale（当前 LANG=%s LC_ALL=%s LC_CTYPE=%s）。\n' \
    "${LANG:-}" "${LC_ALL:-}" "${LC_CTYPE:-}" >&2
  printf '  请以 LANG=C.UTF-8 运行；或设 BUPTY_FORCE_UTF8=1 强制按 UTF-8 口径量。\n' >&2
  rm -rf "${XDG_CONFIG_HOME}"
  exit 2
fi

# 用 fixture 填充视图数据（离线确定性）。真实课表/空教室 fixture 若存在则用之。
_setup_data() {
  if [[ -f "${BUPTY_HOME}/tests/fixtures/schedule.json" ]]; then
    SCHEDULE_DATA="$(cat "${BUPTY_HOME}/tests/fixtures/schedule.json")"
    SCHEDULE_ACCOUNT="2025000000"; SCHEDULE_LOADED=1
  fi
  if [[ -f "${BUPTY_HOME}/tests/fixtures/classrooms.json" ]]; then
    CLASSROOMS_DATA="$(cat "${BUPTY_HOME}/tests/fixtures/classrooms.json")"
    CLASSROOMS_ACCOUNT="2025000000"; CLASSROOMS_LOADED=1
  fi
  if [[ -f "${BUPTY_HOME}/tests/fixtures/booking-roommenu.json" ]]; then
    BOOKING_CATEGORIES="$(_booking_parse_categories "$(cat "${BUPTY_HOME}/tests/fixtures/booking-roommenu.json")")"
    BOOKING_ACCOUNT="2025000000"; BOOKING_LOADED=1
    BOOKING_TAB=0
    BOOKING_DEPTH=0
  fi
}

# 显示宽度：**直接复用 lib/core.sh 的 _core_width（单一真源）**，不再自带一份口径。
# 旧实现把「非 ASCII 一律 2 列」（cp > 255），而合并后的引擎按 East Asian Width 判列、
# 歧义类字符（盒线 U+2500–U+257F、⚙ █ ● ▶ ▸ … 等）在 BUPTY_AMBIG_W=1 时是 **1 列**。
# 两套口径一漂移，脚本就会把这些字符多算 1 列，量出的行宽比真实宽 → 假报「超宽」。
_width() {
  _core_width "$1"
  printf '%s' "${_CORE_W}"
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
  # 页眉：**字面量「bupty」或首页大字符块**二者其一即可。宽屏（≥47 列且行数够档，
  # 见 lib/banner.sh 的分档门槛）时页眉被大字符块替代，只认字面量会必然误报「缺页眉」。
  # 认块时要求 (a) banner_init 判定为激活，且 (b) 帧里真的出现了块的首行（不是空口）。
  if ! printf '%s' "${out}" | grep -q 'bupty'; then
    banner_init
    # banner_plain_row 返回的是 **ASCII 画布**（1..7 是占位数字），帧里出现的是
    # _banner_translate 翻好的字形行——用产品自己的翻译函数，别在这里复刻那张映射表。
    _banner_translate "$(banner_plain_row 0)"
    if (( ${BANNER_ACTIVE:-0} )) \
       && printf '%s' "${out}" | grep -qF "${_BANNER_TEXT}"; then
      header=""
    else
      header="缺页眉"
    fi
  fi
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
