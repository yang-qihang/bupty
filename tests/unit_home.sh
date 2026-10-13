#!/usr/bin/env bash
# tests/unit_home.sh —— 首页模块网格的几何单测（对应 lib/views/home.sh）
#
# 本文件不强制多字节模式：它断言的是**与边框字形无关的不变量**——
# 「每行恰好铺满」「卡片分栏列位置恒定」（仅卡片档位 A/B；档位 C 是纵向列表，
# 信息列在放不下时按设计整段省略，各行本就不同宽）。两种模式下都必须全绿：
#   * 字符模式（BUPTY_MB=1）：amb=1 → Unicode 边框（┌─┐），▶ 与 ─ 同为 1 列
#   * 字节模式（BUPTY_MB=0）：core_utf8 假 → 边框退 ASCII（+-|）
#   * amb=2（CJK 终端）：ICON_UNICODE_W=2 → ui_box_init 退 ASCII 边框，
#     而 ▶(U+25B6) 是真歧义类实占 2 列 ← 曾经的破绽就在这里
#
# 回归目标（真实存在过的 bug，已在真终端配置下复现过）：
#   档位 A 选中卡片的顶边曾写死「▶ 之后 IW-2 根横线」，等价于假设 w(▶)==w(横线)。
#   该假设在「ASCII 边框 + amb=2」下不成立（1 ≠ 2），于是选中卡片顶边宽 1 列，
#   79 列终端上整行渲染成 80 列，第 3 行顶出右边界。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 隔离配置目录：避免读到开发者本机已保存的主题，保证结果可复现。
export XDG_CONFIG_HOME="$(mktemp -d)"
trap 'rm -rf "${XDG_CONFIG_HOME}"' EXIT

# tui.sh 自己会 `set -euo pipefail`，而本测试靠断言计数判定成败，必须自己控制失败处理：
# 载入后立刻关掉 errexit（与 tests/unit_responsive.sh 同一约定）。
# 不关的话 render_home 的**合法**返回码 1 会把整个测试静默杀掉——它末行是
# `(( r == 0 )) && printf '\n'`，第二行取假即返回 1（生产侧用 tui.sh:244
# 的 `render_${TUI_VIEW} || true` 兜住，见 lib/views/home.sh）。
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tui.sh"
set +e
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

ui_size() { :; }
creds_exists() { return 1; }

# ---------------------------------------------------------------------------
# 测试专用小工具
# ---------------------------------------------------------------------------

_H_LINES=()
_H_WIDTHS=()

# 去掉 ANSI 转义（只处理 CSI：ESC [ 参数 字母）。
# 刻意不写 ${s//$'\033'\[[0-9;]*[a-zA-Z]/} —— bash 的 * 是贪婪的，
# 那样写会从第一个转义一路删到行尾，量出来恒为 0，测试会「静默地永远通过」。
h_strip_ansi() {
  local s="$1" out=""
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"
    s="${s#*$'\033['}"
    s="${s#*[a-zA-Z]}"
  done
  printf '%s%s' "${out}" "${s}"
}

# 一行的显示列数。
h_width() {
  _core_width "${1:-}"
  printf '%s' "${_CORE_W}"
}

# 渲染一帧首页到 _H_LINES（每行已去转义）与 _H_WIDTHS（每行显示列数）。
# 一帧只渲染一次，宽度与分栏两项检查共用同一份输出，避免两次渲染不一致。
h_frame() {
  local line
  _H_LINES=()
  _H_WIDTHS=()
  while IFS= read -r line; do
    line="$(h_strip_ansi "${line}")"
    _H_LINES+=("${line}")
    _H_WIDTHS+=("$(h_width "${line}")")
  done < <(render_home)
}

# 所有非空行宽度是否一致（一致是网格的基本不变量）。
# 一致 → _H_COMMON 为公共宽度、_H_BAD 为空；否则 _H_BAD 描述异常行。
# 这个判据与多字节模式无关，且能抓到本次回归：选中卡片宽 1 列时，
# 只有顶边那一行会变宽，于是「各行等宽」立刻不成立。
h_uniform() {
  local i w="" out=""
  for i in "${!_H_WIDTHS[@]}"; do
    ((_H_WIDTHS[i] == 0)) && continue
    if [[ -z "${w}" ]]; then
      w="${_H_WIDTHS[i]}"
    elif ((_H_WIDTHS[i] != w)); then
      out+="${out:+ }$((i + 1)):${_H_WIDTHS[i]}"
    fi
  done
  _H_COMMON="${w}"
  if [[ -n "${out}" ]]; then _H_BAD="异常行 ${out}（首行 ${w} 列）"; else _H_BAD=""; fi
}

# 是否有行超出 limit 列。
h_overflow() {
  local limit="$1" i out=""
  for i in "${!_H_WIDTHS[@]}"; do
    ((_H_WIDTHS[i] > limit)) && out+="${out:+ }$((i + 1)):${_H_WIDTHS[i]}"
  done
  printf '%s' "${out}"
}

# 按 amb 忠实复现真实启动流程的推导链。
# 注意 ui_box_init 没有幂等哨兵（不像 icon_init 有 _ICON_INITIALIZED）：它两个分支都
# 显式赋值，本身就是可重复调用的，所以这里只需重置 icon 侧的状态。
# 它判定 Unicode/ASCII 边框看的是 BUPTY_AMBIG_W（不是 ICON_UNICODE_W），见 lib/ui.sh。
h_set_amb() {
  local amb="$1"
  BUPTY_AMBIG_W="${amb}"
  if ((amb == 2)); then export BUPTY_FORCE_ICONS=bg; else export BUPTY_FORCE_ICONS=half; fi
  _ICON_INITIALIZED=""
  icon_init
  ui_box_init
}

# 把数组按空格拼成一个串，便于 assert_eq 比对。
h_join() {
  local out="" x
  for x in "$@"; do out+="${out:+ }${x}"; done
  printf '%s' "${out}"
}

ui_theme_init

# ---------------------------------------------------------------------------
# 0. 反向对照：证明本文件的断言「失败得出来」
# ---------------------------------------------------------------------------
# 前面踩过坑：一条恒真的断言会让整份测试静默全绿。先拿一条**故意做错**的行
# 喂进同一条量宽链路，确认它真的会被量出超宽、判为溢出。
t_begin "反向对照"
UI_COLS=40
assert_eq "$(h_width "$(printf '%*s' "$((UI_COLS + 1))" '')")" "41" \
  "刻意超宽一行必须量出 41 列（否则量宽链路是坏的）"
assert_eq "$(( $(h_width "$(printf '%*s' "$((UI_COLS + 1))" '')") > UI_COLS ))" "1" \
  "该行必须被判为溢出"
assert_eq "$(h_width '正常一行')" "8" "正常行量宽必须准确"

# ---------------------------------------------------------------------------
# 1. 档位选择：A / B / C 的阈值
# ---------------------------------------------------------------------------
t_begin "档位阈值"
# A：UI_COLS >= 79 且 body(=UI_ROWS-5) >= 17
UI_COLS=79 UI_ROWS=22
_home_layout
assert_eq "${_HOME_TIER}/${_HOME_COLS}" "A/3" "79 列 × body17 → 档位 A 三列"

UI_COLS=78 UI_ROWS=22
_home_layout
assert_eq "${_HOME_TIER}" "B" "78 列放不下三张 25 列卡（几何需 79）→ 退档位 B"

UI_COLS=79 UI_ROWS=21
_home_layout
assert_eq "${_HOME_TIER}" "B" "三张卡需 body>=17，body16 → 退档位 B"

# B：UI_COLS >= 40 且 body >= 11
UI_COLS=40 UI_ROWS=16
_home_layout
assert_eq "${_HOME_TIER}/${_HOME_COLS}" "B/2" "40 列 × body11 → 档位 B 两列"

UI_COLS=39 UI_ROWS=24
_home_layout
assert_eq "${_HOME_TIER}" "C" "39 列 → 档位 C"

UI_COLS=79 UI_ROWS=15
_home_layout
assert_eq "${_HOME_TIER}" "C" "高度不足 body10 → 档位 C"

# ---------------------------------------------------------------------------
# 2. 档位 A：卡片几何与分栏列位置（本次回归的核心）
# ---------------------------------------------------------------------------
# 渲染一帧约 2.6s（每帧 icon_render 要 12 次 fork），矩阵刻意收窄：
#   cols 取 79（三张卡恰好放下的边界，本次回归的现场）与 120（宽终端补边）；
#   sel 取 0/1/5（第一行首卡、同行邻卡、第二行末卡）——六张卡几何同构，
#   而回归只对「被选中的那一张」生效，覆盖到每个位置一次即可。
for amb in 1 2; do
  h_set_amb "${amb}"
  for cols in 79 120; do
    UI_COLS="${cols}"
    UI_ROWS=24
    _home_layout
    t_begin "档位A amb=${amb} cols=${cols}"
    assert_eq "${_HOME_TIER}" "A" "${cols} 列 × 24 行应为档位 A"

    # 档位 A 的几何：三个 25 列卡片 + 两个 2 列间隙 = 79 列，整体居中 →
    # 行宽恒为 pad + 79（卡片尺寸固定，不随终端拉伸）。
    pad=$(((cols - 79) / 2))
    want_w=$((pad + 79))

    for sel in 0 1 5; do
      HOME_FOCUS="grid"
      HOME_SEL="${sel}"
      h_frame
      # 1) 各行必须等宽——选中卡片宽 1 列时只有顶边那一行会变宽，这里立刻露馅。
      h_uniform
      assert_eq "${_H_BAD}" "" "sel=${sel} 所有非空行等宽"
      # 2) 公共宽度必须精确等于 pad+79 —— 把每张卡片钉死在 25 列。
      assert_eq "${_H_COMMON}" "${want_w}" "sel=${sel} 行宽恒为 pad+79"
      # 3) 不得顶出右边界。
      assert_eq "$(h_overflow "${cols}")" "" "sel=${sel} 无行超出 ${cols} 列"
    done
  done
done

# ---------------------------------------------------------------------------
# 3. 档位 B / C：任何一行都不得超出 UI_COLS，帧高不得超正文
# ---------------------------------------------------------------------------
# 显式钉住 amb：下面的期望值不依赖上一节循环结束时的残留状态。
h_set_amb 2
for wh in "40 24" "78 22" "79 16" "24 24" "16 12" "100 14"; do
  read -r cols rows <<< "${wh}"
  UI_COLS="${cols}" UI_ROWS="${rows}"
  _home_layout
  t_begin "档位${_HOME_TIER} cols=${cols} rows=${rows}"
  for sel in 0 5; do
    HOME_FOCUS="grid"
    HOME_SEL="${sel}"
    h_frame
    # 「各行等宽」只对卡片式档位 A/B 成立：档位 C 走 _home_render_list，
    # 信息列在 rest < 1 时按设计整段省略，各行宽度本就该不同（窄终端尤其明显）。
    if [[ "${_HOME_TIER}" != "C" ]]; then
      h_uniform
      assert_eq "${_H_BAD}" "" "sel=${sel} 所有非空行等宽"
    fi
    assert_eq "$(h_overflow "${cols}")" "" "sel=${sel} 无行超出 ${cols} 列"
    assert_eq "$(( ${#_H_LINES[@]} <= rows - 5 ))" "1" "帧高 <= UI_ROWS-5"
  done
done

# ---------------------------------------------------------------------------
# 3b. 极窄 / 极矮兜底
# ---------------------------------------------------------------------------
# 档位 C 是 UI_COLS < 40 的兜底档，代码里没有任何宽度/高度下限，
# 因此下面这两条不变量只能靠它自己撑住。两处都真实溢出过：
#   * 只剩 1 列时，选中标记 ▶(U+25B6) 在 amb=2 下实占 2 列——只截断名字、
#     保留标记，整行就恒为 2 列（名字截断分支里又漏了「标记自己放不下」这一档）。
#   * UI_ROWS <= 5 时正文预算为 0 或负，早先为了「至少画一行」硬把 visible 抬到 1，
#     于是 5 行终端渲染出 6 行，把帧顶穿。
for amb in 1 2; do
  h_set_amb "${amb}"
  UI_COLS=1 UI_ROWS=24
  _home_layout
  t_begin "极窄 amb=${amb} cols=1"
  for sel in 0 5; do
    HOME_FOCUS="grid"
    HOME_SEL="${sel}"
    h_frame
    assert_eq "$(h_overflow 1)" "" "sel=${sel} 无行超出 1 列"
  done
done

h_set_amb 2
for rows in 1 5 6; do
  UI_COLS=24 UI_ROWS="${rows}"
  _home_layout
  t_begin "极矮 rows=${rows}"
  HOME_FOCUS="grid"
  HOME_SEL=5
  h_frame
  # 预算为负时钳到 0：能画 0 行已是极限，这里比的是「不超过」。
  want=$(( rows - 5 ))
  (( want < 0 )) && want=0
  assert_eq "$(( ${#_H_LINES[@]} <= want ))" "1" "帧高 <= max(0, UI_ROWS-5)"
done

# ---------------------------------------------------------------------------
# 4. 上下左右导航
# ---------------------------------------------------------------------------
t_begin "导航"
# 档位 A（3 列）：0..5 排成 2×3
UI_COLS=79 UI_ROWS=24
_home_layout
HOME_FOCUS="grid" HOME_SEL=0
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "3" "A 档从 0 下移落到 3"
_home_move_vertical -1 && assert_eq "${HOME_SEL}" "0" "A 档从 3 上移回到 0"
assert_fail _home_move_vertical -1
assert_ok _home_move_vertical 1

# 档位 B（2 列）：0..5 排成 3×2
UI_COLS=40 UI_ROWS=24
_home_layout
HOME_FOCUS="grid" HOME_SEL=5
assert_fail _home_move_vertical 1
_home_move_vertical -1 && assert_eq "${HOME_SEL}" "3" "B 档从 5 上移落到 3"

# 档位 C（1 列）：每行一张
UI_COLS=24 UI_ROWS=24
_home_layout
HOME_FOCUS="grid" HOME_SEL=0
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "1" "C 档逐行下移"

# 左右键不越列；设置焦点时左右键不动网格
UI_COLS=79 UI_ROWS=24
_home_layout
HOME_FOCUS="grid" HOME_SEL=0
handle_home_key LEFT
assert_eq "${HOME_SEL}" "0" "首列再按左不动"
HOME_SEL=2
handle_home_key RIGHT
assert_eq "${HOME_SEL}" "2" "第三列（行末）再按右不动"
HOME_SEL=1
handle_home_key LEFT
assert_eq "${HOME_SEL}" "0" "第二列按左回到第一列"

# ↑ 从第一行进入设置焦点；↓ 从设置焦点回到网格
HOME_FOCUS="grid" HOME_SEL=3
handle_home_key UP
assert_eq "${HOME_FOCUS}" "grid" "A 档第二行按上仍在网格"
assert_eq "${HOME_SEL}" "0" "A 档第二行按上落到第一行"
HOME_SEL=0
handle_home_key UP
assert_eq "${HOME_FOCUS}" "settings" "首行按上进入设置焦点"
handle_home_key DOWN
assert_eq "${HOME_FOCUS}" "grid" "设置焦点按下回到网格"
HOME_FOCUS="settings" HOME_SEL=0
handle_home_key LEFT
assert_eq "${HOME_SEL}" "0" "设置焦点时左键不动网格"

t_summary
