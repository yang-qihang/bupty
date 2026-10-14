#!/usr/bin/env bash
# tests/unit_icons.sh —— 图标层单测（对应 lib/icons.sh 的 half/bg/off 三档渲染）
#
# 覆盖两种 bash 语义，本文件在哪种模式下跑都应当全绿：
#   * 字节模式：LANG/LC_ALL/LC_CTYPE 都没设（MSYS2/Git Bash 常见），BUPTY_MB=0
#   * 字符模式：LANG=zh_CN.UTF-8（WSL/Linux / 装了 UTF-8 locale 的 Git Bash），BUPTY_MB=1
# 断言里出现的非 ASCII 字符一律用 \xNN 字节字面量构造，源码本身不含非 ASCII 字符。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck source=/dev/null
source "${BUPTY_HOME}/lib/icons.sh"
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# ---------------------------------------------------------------------------
# 测试专用小工具
# ---------------------------------------------------------------------------

_ICON_T_ESC=$'\033'
_ICON_T_COLOR=$'\033[38;5;203m'   # 调用方传入的前景 SGR
_ICON_T_BLANK="$(printf '%12s' '')"   # 12 个空格

# 去掉 ANSI SGR（覆盖 38;5;N / 48;5;N / 0 等）。sed 用「ESC + [数字;]* + m」逐段匹配，
# 不像 bash 的 ${s//…} 那样贪婪，不会吞掉相邻两段之间的空格。
i_strip() {
  printf '%s' "${1:-}" | sed "s/${_ICON_T_ESC}\[[0-9;]*m//g"
}

# 取 _core_width 的结果（只写全局 _CORE_W，不写 stdout）。
i_width() {
  _core_width "${1:-}"
  printf '%s' "${_CORE_W}"
}

# 强制按字节数取长度（与当前 locale / BUPTY_MB 无关）。
i_bytes() {
  local s="${1:-}"
  ( LC_ALL=C; printf '%s' "${#s}" )
}

# 变量是否已定义（区别于「已定义为空串」）。
i_is_set() {
  [[ -v "$1" ]]
}

# 字符串是否含 ESC 转义字节。
i_has_esc() {
  [[ "$1" == *$'\033'* ]]
}

# 扫描一行，验证每个 SGR open 都在同一行内被 \033[0m 闭合（否则颜色会渗到下一行）。
# 只关心 ASCII 的 ESC/[0-9;m，字符/字节两种模式下索引语义一致。返回 0=全部闭合。
i_sgr_closed() {
  local s="${1:-}" i n c j d seq open=0 esc=$'\033'
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [[ "${c}" == "${esc}" && "${s:i+1:1}" == "[" ]]; then
      j=$((i + 2))
      seq=""
      while ((j < n)); do
        d="${s:j:1}"
        if [[ "${d}" == "m" ]]; then
          break
        fi
        seq+="${d}"
        j=$((j + 1))
      done
      if [[ "${seq}" == "0" ]]; then
        open=$((open - 1))
      else
        open=$((open + 1))
      fi
      if ((open < 0)); then
        return 1
      fi
      i=$((j))
    fi
  done
  if ((open == 0)); then
    return 0
  fi
  return 1
}

i_starts_with() {
  [[ "$1" == "$2"* ]]
}

i_ends_with() {
  [[ "$1" == *"$2" ]]
}

# 字符串是否含裸复位 \033[0m。
i_has_reset() {
  [[ "${1:-}" == *$'\033[0m'* ]]
}

# 一行里出现子串 sub 的次数（最短匹配逐个剥，不做贪婪正则）。
i_count() {
  local s="${1:-}" sub="${2:-}" n=0
  while [[ "${s}" == *"${sub}"* ]]; do s="${s#*"${sub}"}"; n=$((n + 1)); done
  printf '%s' "${n}"
}

# 复位图标层状态，以便重新跑 icon_init 的某个分支。
i_reset_icons() {
  unset _ICON_INITIALIZED
  unset ICON_UNICODE_W 2>/dev/null || true
  ICON_MODE="off"
  ICON_ROWS=()
}

# ---------------------------------------------------------------------------
# A. 三档 footprint 一致性（half / bg / off，遍历全部 ICON_KEYS 键 × 6 行）
# 键数不写死：lib/icons.sh 的 ICON_KEYS 已从 6 个增到 7 个（新增 booking），
# 这里跟着 ${ICON_KEYS[@]} 走，增键自动纳入覆盖。
# ---------------------------------------------------------------------------
# 三档渲染的「占用」必须完全一致：都是 6 行 × 12 显示列，否则上层布局数学会错。
i_check_footprint() {
  local mode="$1" key row plain i
  for key in "${ICON_KEYS[@]}"; do
    icon_render "${key}" "${_ICON_T_COLOR}"
    assert_eq "${#ICON_ROWS[@]}" "6" "[${mode}/${key}] ICON_ROWS 长度应为 6"
    for ((i = 0; i < 6; i++)); do
      row="$(i_strip "${ICON_ROWS[i]}")"
      assert_eq "$(i_width "${row}")" "12" "[${mode}/${key}/行${i}] 去转义后显示宽度应为 12"
      plain="$(icon_plain_row "${i}")"
      assert_eq "$(i_bytes "${plain}")" "12" "[${mode}/${key}/行${i}] icon_plain_row 应为 12 字节"
    done
  done
}

for mode in half bg off; do
  i_reset_icons
  BUPTY_FORCE_ICONS="${mode}"
  icon_init
  case "${mode}" in
    half) BUPTY_AMBIG_W=1 ;;
    bg)   BUPTY_AMBIG_W=2 ;;
    off)  BUPTY_AMBIG_W=1 ;;
  esac
  t_begin "A 三档 footprint [${mode}]"
  i_check_footprint "${mode}"
done

# ---------------------------------------------------------------------------
# B. icon_init 的分支与优先级
# ---------------------------------------------------------------------------
t_begin "B1 FORCE=half"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
assert_eq "${ICON_MODE}" "half" "FORCE=half → ICON_MODE=half"
assert_eq "${ICON_UNICODE_W}" "1" "FORCE=half → ICON_UNICODE_W=1"
assert_ok i_is_set ICON_UNICODE_W

t_begin "B2 FORCE=bg"
i_reset_icons
BUPTY_FORCE_ICONS=bg
icon_init
assert_eq "${ICON_MODE}" "bg" "FORCE=bg → ICON_MODE=bg"
assert_eq "${ICON_UNICODE_W}" "2" "FORCE=bg → ICON_UNICODE_W=2"
assert_ok i_is_set ICON_UNICODE_W

t_begin "B3 FORCE=off（ICON_UNICODE_W 必须未定义，而非空串）"
i_reset_icons
BUPTY_FORCE_ICONS=off
icon_init
assert_eq "${ICON_MODE}" "off" "FORCE=off → ICON_MODE=off"
assert_fail i_is_set ICON_UNICODE_W

t_begin "B4 非 TTY 默认 off"
i_reset_icons
unset BUPTY_FORCE_ICONS
icon_init </dev/null >/dev/null 2>&1
assert_eq "${ICON_MODE}" "off" "非 TTY → ICON_MODE=off"
assert_fail i_is_set ICON_UNICODE_W

t_begin "B5 幂等"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
assert_eq "${ICON_MODE}" "half" "首次 icon_init → half"
assert_eq "${ICON_UNICODE_W}" "1" "首次 icon_init → W=1"
BUPTY_FORCE_ICONS=bg
icon_init
assert_eq "${ICON_MODE}" "half" "第二次 icon_init 不改 ICON_MODE"
assert_eq "${ICON_UNICODE_W}" "1" "第二次 icon_init 不改 ICON_UNICODE_W"
assert_ok i_is_set _ICON_INITIALIZED

t_begin "B6 stdout 洁净（非 TTY）"
i_reset_icons
unset BUPTY_FORCE_ICONS
out="$(icon_init </dev/null 2>/dev/null; printf 'X')"
assert_eq "${out}" "X" "icon_init 不得向 stdout 写任何东西"

t_begin "B7 stdout 洁净（FORCE=half）"
i_reset_icons
BUPTY_FORCE_ICONS=half
out="$(icon_init </dev/null 2>/dev/null; printf 'X')"
assert_eq "${out}" "X" "icon_init(half) 不得向 stdout 写任何东西"

# ---------------------------------------------------------------------------
# C. icon_render 的边界
# ---------------------------------------------------------------------------
t_begin "C1 未知键"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
rc=0
icon_render "nonexistent" "${_ICON_T_COLOR}" || rc=$?
assert_eq "${rc}" "1" "未知键 → 返回非 0"
assert_eq "${#ICON_ROWS[@]}" "6" "未知键 → 六行"
for ((i = 0; i < 6; i++)); do
  assert_eq "${ICON_ROWS[i]}" "${_ICON_T_BLANK}" "未知键 → 行${i} 应为 12 空格"
done

t_begin "C2 空颜色无转义"
for mode in half bg; do
  i_reset_icons
  BUPTY_FORCE_ICONS="${mode}"
  icon_init
  icon_render "assignments" ""
  for ((i = 0; i < 6; i++)); do
    assert_fail i_has_esc "${ICON_ROWS[i]}" "[${mode}] 空颜色行${i} 不应含转义"
    assert_eq "$(i_width "$(i_strip "${ICON_ROWS[i]}")")" "12" "[${mode}] 空颜色行${i} 宽度 12"
  done
done

t_begin "C3 前景色转义闭合 + 不改写调用方"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
color="${_ICON_T_COLOR}"
sgr_before="${color}"
sentinel="sentinel-12345"
icon_render "public" "${color}"
assert_eq "${color}" "${sgr_before}" "icon_render 不得改写调用方颜色变量"
assert_eq "${sentinel}" "sentinel-12345" "icon_render 不得改写调用方全局变量"
assert_eq "${ICON_W}" "12" "icon_render 不得改写 ICON_W"
assert_eq "${ICON_H}" "6" "icon_render 不得改写 ICON_H"
for ((i = 0; i < 6; i++)); do
  row="${ICON_ROWS[i]}"
  assert_ok i_sgr_closed "${row}" "half 前景色行${i} 转义应闭合"
  assert_ok i_starts_with "${row}" "${color}" "half 前景色行${i} 应以颜色 SGR 开头"
  assert_ok i_ends_with "${row}" "${_ICON_RESET}" "half 前景色行${i} 应以复位结尾"
done

# bg 模式：每个着色空格是「bg_sgr + 空格 + reset」的成对结构，也要全部闭合。
i_reset_icons
BUPTY_FORCE_ICONS=bg
icon_init
icon_render "public" "${_ICON_T_COLOR}"
for ((i = 0; i < 6; i++)); do
  assert_ok i_sgr_closed "${ICON_ROWS[i]}" "bg 前景色行${i} 转义应闭合"
done

# ---------------------------------------------------------------------------
# D. 与宽度引擎的联动（关键正确性断言）
# ---------------------------------------------------------------------------
# BUPTY_AMBIG_W 必须与 ICON_UNICODE_W 一致，图标才恰好 12 列。
t_begin "D1 half 档联动（ICON_UNICODE_W=1 ↔ BUPTY_AMBIG_W=1）"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
assert_eq "${ICON_UNICODE_W}" "1" "half → ICON_UNICODE_W=1"
BUPTY_AMBIG_W=1
icon_render "public" "${_ICON_T_COLOR}"
for ((i = 0; i < 6; i++)); do
  assert_eq "$(i_width "$(i_strip "${ICON_ROWS[i]}")")" "12" "half 档 BUPTY_AMBIG_W=1 时行${i} 宽 12"
done
# 反证：若 BUPTY_AMBIG_W 与 ICON_UNICODE_W 不一致（=2），半块行会顶破 12 列，
# 说明这个联动不是摆设——两处必须同源。
BUPTY_AMBIG_W=2
maxw=0
for ((i = 0; i < 6; i++)); do
  w="$(i_width "$(i_strip "${ICON_ROWS[i]}")")"
  if ((w > maxw)); then maxw=$w; fi
done
assert_ok test "$maxw" -gt 12
BUPTY_AMBIG_W=1

t_begin "D2 bg 档联动（ICON_UNICODE_W=2 ↔ BUPTY_AMBIG_W=2）"
i_reset_icons
BUPTY_FORCE_ICONS=bg
icon_init
assert_eq "${ICON_UNICODE_W}" "2" "bg → ICON_UNICODE_W=2"
BUPTY_AMBIG_W=2
icon_render "public" "${_ICON_T_COLOR}"
for ((i = 0; i < 6; i++)); do
  assert_eq "$(i_width "$(i_strip "${ICON_ROWS[i]}")")" "12" "bg 档 BUPTY_AMBIG_W=2 时行${i} 宽 12"
done
BUPTY_AMBIG_W=1

# ---------------------------------------------------------------------------
# E. 三参数形式：复位串必须用「传进去的那个」，而不是缺省 _ICON_RESET
# ---------------------------------------------------------------------------
# 背景：本轮的图标漏色修复恰恰落在**第三参数**上——生产调用点 lib/views/home.sh:102
# 传的是 ${UI_RESET}（复位 + 立刻补底色），而两参调用用缺省的 _ICON_RESET（裸 \033[0m）。
# 旧测试只覆盖两参形式（复位走缺省），所以「第三参数到底有没有被用上」是零覆盖的。
# 这一节把「传进去的复位串」与「缺省的 _ICON_RESET」区分开：形态相近但**不相等**
# （_ICON_RESET 是 _ICON_T_RESET 的前缀），于是「用了传入串」与「用了缺省串」可判别。
_ICON_T_RESET=$'\033[0m\033[48;5;233m'   # 形如某主题的 UI_RESET；与 _ICON_RESET 不同

# _ICON_RESET 必须是 _ICON_T_RESET 的前缀（否则下面的判别不成立）。
t_begin "E0 判别基准"
assert_eq "$([[ "${_ICON_T_RESET}" == "${_ICON_RESET}"* ]] && printf yes || printf no)" "yes" \
  "_ICON_RESET 必须是 _ICON_T_RESET 的前缀（否则「结尾是不是缺省串」判不出来）"
assert_eq "$([[ "${_ICON_T_RESET}" == "${_ICON_RESET}" ]] && printf same || printf diff)" "diff" \
  "两个复位串必须不同（否则本节的断言退化成恒真）"

# 一行里所有复位都必须是传入串：把传入串整段剥掉后，不得再残留任何裸 \033[0m。
i_reset_all_passed() {
  local row="$1" rest="${1}"
  while [[ "${rest}" == *"${_ICON_T_RESET}"* ]]; do rest="${rest#*"${_ICON_T_RESET}"}"; done
  ! i_has_reset "${rest}"
}

t_begin "E1 三参 half：行尾/行内复位都用传入串"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
BUPTY_AMBIG_W=1
icon_render "public" "${_ICON_T_COLOR}" "${_ICON_T_RESET}"
for ((i = 0; i < 6; i++)); do
  row="${ICON_ROWS[i]}"
  assert_ok i_ends_with "${row}" "${_ICON_T_RESET}" "half 行${i} 应以传入的复位串结尾"
  # 关键判别：不得以缺省的 _ICON_RESET 结尾——它正是漏色的那个裸复位。
  assert_fail i_ends_with "${row}" "${_ICON_RESET}" "half 行${i} 不得以缺省 _ICON_RESET 结尾"
  assert_ok test "$(i_count "${row}" "${_ICON_T_RESET}")" -ge 1
  assert_ok i_reset_all_passed "${row}" "half 行${i} 剥掉传入串后不得残留裸复位"
  # 宽度与两参一致（换复位串不得改几何）。
  assert_eq "$(i_width "$(i_strip "${row}")")" "12" "half 行${i} 去转义后仍为 12 列"
done

t_begin "E2 三参 bg：逐格复位都用传入串"
i_reset_icons
BUPTY_FORCE_ICONS=bg
icon_init
BUPTY_AMBIG_W=2
icon_render "public" "${_ICON_T_COLOR}" "${_ICON_T_RESET}"
i_bg_reset_total=0
for ((i = 0; i < 6; i++)); do
  row="${ICON_ROWS[i]}"
  n="$(i_count "${row}" "${_ICON_T_RESET}")"
  i_bg_reset_total=$(( i_bg_reset_total + n ))
  assert_ok i_reset_all_passed "${row}" "bg 行${i} 剥掉传入串后不得残留裸复位"
  assert_eq "$(i_width "$(i_strip "${row}")")" "12" "bg 行${i} 去转义后仍为 12 列"
done
# 整帧至少要有一个着色格（否则上面的「不得残留裸复位」全是空集真命题）。
assert_ok test "${i_bg_reset_total}" -ge 1
# 反证：把传入串写坏成缺省裸复位，计数判据必须能分辨（证明 i_count 不是恒值）。
assert_eq "$(i_count "${_ICON_T_RESET}" "${_ICON_T_RESET}")" "1" "i_count 对单次出现应报 1"
assert_eq "$(i_count "${_ICON_T_RESET}" "${_ICON_RESET}")" "1" "前缀也算一次匹配（用于判别基准）"

t_begin "E3 两参形式仍用缺省 _ICON_RESET（三参不得污染缺省路径）"
i_reset_icons
BUPTY_FORCE_ICONS=half
icon_init
BUPTY_AMBIG_W=1
icon_render "public" "${_ICON_T_COLOR}"
for ((i = 0; i < 6; i++)); do
  row="${ICON_ROWS[i]}"
  assert_ok i_ends_with "${row}" "${_ICON_RESET}" "两参 half 行${i} 应仍以缺省 _ICON_RESET 结尾"
  assert_fail i_ends_with "${row}" "${_ICON_T_RESET}" "两参 half 行${i} 不应出现传入串（证明参数确实被区分对待）"
done

t_summary
