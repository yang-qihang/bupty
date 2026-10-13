#!/usr/bin/env bash
# docs/home-card-mock.sh —— 首页模块卡片的真预览（设计评审用）。
#
# 和早先的版本不同：这里**直接调用产品代码**——lib/icons.sh 的图标层和
# lib/core.sh 的宽度引擎——而不是自己另画一套网格。所以你在终端里看到的
# 形状、颜色、对齐，就是接进 bupty 之后会出现的样子。
#
# 用法：
#   bash docs/home-card-mock.sh              # 80 列，带颜色
#   bash docs/home-card-mock.sh 100          # 指定宽度，看响应式退化
#   bash docs/home-card-mock.sh 60
#   BUPTY_FORCE_ICONS=bg   bash docs/home-card-mock.sh 80   # 预览兜底档
#   BUPTY_FORCE_ICONS=off  bash docs/home-card-mock.sh 80   # 预览无图标档
#
# 注意：宽度是这个脚本的**唯一**输入。真实的 bupty 会从 stty 读终端尺寸。

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC1091
source lib/core.sh
# shellcheck disable=SC1091
source lib/icons.sh

W=${1:-80}
# icon_init 自己会读 BUPTY_FORCE_ICONS（half/bg/off），并在非 TTY 时退回 off。
icon_init

R=$'\033[0m'
C_ACC=$'\033[38;5;39m'
C_TXT=$'\033[38;5;252m'
C_MUT=$'\033[38;5;244m'
C_BOR=$'\033[38;5;239m'
C_HL=$'\033[38;5;15;48;5;24m'
C_DAN=$'\033[38;5;203m'
C_OK=$'\033[38;5;114m'
C_PUR=$'\033[38;5;135m'
C_WAR=$'\033[38;5;215m'

KEYS=(assignments schedule classrooms grades exams public)
LABELS=("作业 DDL" "课表" "空教室" "成绩" "考试" "公共查询")
INFOS=("3 个待办" "12 节课" "空 4 间" "GPA 3.72" "2 门待考" "常用入口")
COLORS=("${C_DAN}" "${C_ACC}" "${C_OK}" "${C_PUR}" "${C_WAR}" "${C_ACC}")

# 显示列宽（无 fork：_core_width 把结果写进全局 _CORE_W）
w_of() { _core_width "$1"; }

# 按显示列宽补齐到 target。超出则原样返回（截断交给 core_fit）。
padto() {
  local s="$1" target="$2" lack
  w_of "${s}"
  lack=$((target - _CORE_W))
  if ((lack <= 0)); then printf '%s' "${s}"; return; fi
  printf '%s%*s' "${s}" "${lack}" ''
}

hline() { # <列数> <颜色>
  local n="$1" col="$2" i
  printf '%s' "${col}"
  for ((i = 0; i < n; i++)); do printf '─'; done
  printf '%s' "${R}"
}

# 卡片：外宽 CW（含边框），内宽 IW=CW-2，高 8 行。
# 行 0 上边框 / 1..6 图标 6 行 / 7 下边框；名称与数据压在图标第 3、4 行。
card_row() { # <内宽> <边框色> <图标行> <图标色> <右文本> <文本色>
  local iw="$1" bcol="$2" ic="$3" icol="$4" txt="$5" tcol="$6"
  local tw=$((iw - ICON_W - 2))
  ((tw < 1)) && tw=1
  printf '%s│%s' "${bcol}" "${R}"
  if [[ -n "${ic}" ]]; then printf '%s%s%s' "${icol}" "${ic}" "${R}"; else printf '%*s' "${ICON_W}" ''; fi
  printf '  '
  printf '%s%s%s' "${tcol}" "$(padto "${txt}" "${tw}")" "${R}"
  printf '%s│%s\n' "${bcol}" "${R}"
}

# 档位 B：带框迷你卡片（无图标），2 列 × 3 行，每张 3 行高
render_mini() {
  local w="$1" pad="$2" gap=2
  local cw=$(( (w - pad - gap) / 2 ))
  local iw=$((cw - 2))
  local sp i row
  printf -v sp '%*s' "${pad}" ''
  for ((row = 0; row < 3; row++)); do
    local -a block=()
    for ((i = row * 2; i < row * 2 + 2; i++)); do
      local bcol="${C_BOR}" tcol="${C_TXT}" mark="▸" mcol="${C_MUT}"
      ((i == 1)) && { bcol="${C_ACC}"; tcol="${C_HL}"; mark="▶"; mcol="${C_ACC}"; }
      local nm=" ${LABELS[$i]}" info="${INFOS[$i]}"
      local line="${mark}${nm}" rest mid="" lw iw2
      # 注意：_CORE_W 是**单个全局变量**，两次调用之间必须先把结果取走，
      # 否则后一次会覆盖前一次 —— 这里踩过，卡片内容行会宽出 2 列。
      w_of "${line}"; lw=${_CORE_W}
      w_of "${info}"; iw2=${_CORE_W}
      rest=$((iw - lw - iw2))
      block+=("${bcol}┌$(hline "${iw}" "${bcol}")┐${R}")
      if ((rest >= 2)); then
        printf -v mid '%*s' "$((rest - 1))" ''
        block+=("${bcol}│${R}${mcol}${mark}${R}${tcol}${nm}${R}${mid}${C_MUT}${info}${R} ${bcol}│${R}")
      else
        # 放不下数据就只留名称；补空格必须按显示列算，不能用 ${#line}（字节模式下会错位）
        w_of "${line}"
        printf -v mid '%*s' "$((iw - _CORE_W - 1))" ''
        block+=("${bcol}│${R}${mcol}${mark}${R}${tcol}${nm}${R}${mid} ${bcol}│${R}")
      fi
      block+=("${bcol}└$(hline "${iw}" "${bcol}")┘${R}")
    done
    for ((i = 0; i < 3; i++)); do
      printf '%s%s%*s%s\n' "${sp}" "${block[$i]}" "${gap}" '' "${block[$((3 + i))]}"
    done
    if ((row < 2)); then printf '\n'; fi
  done
}

# 档位 C/D：单列紧凑行
render_list() {
  local w="$1" pad="$2" i sp
  printf -v sp '%*s' "${pad}" ''
  for ((i = 0; i < 6; i++)); do
    local mark="▸" mcol="${C_MUT}"
    ((i == 1)) && { mark="▶"; mcol="${C_ACC}"; }
    local txt=" ${LABELS[$i]}" info="${INFOS[$i]}" line rest lw iw2
    line="${mark}${txt}"
    w_of "${line}"; lw=${_CORE_W}
    w_of "${info}"; iw2=${_CORE_W}
    rest=$((w - pad - lw - iw2 - 2))
    printf '%s%s%s%s%s' "${sp}" "${mcol}" "${mark}" "${R}" "${C_TXT}"
    printf '%s%s' "${txt}" "${R}"
    if ((rest >= 1)); then
      printf '%*s%s%s%s' "${rest}" '' "${C_MUT}" "${info}" "${R}"
    fi
    printf '\n'
  done
}

render() {
  local w="$1"
  local CW=25 GAP=2 CARD_H=8
  local need3=$((3 * CW + 2 * GAP))

  local pad
  if ((w < 40)); then
    pad=0
    ((w > 24)) && pad=1
    render_list "${w}" "${pad}"
    return
  fi
  if ((w < need3)); then
    pad=$(( (w - (2 * 24 + 2)) / 2 ))
    ((pad < 1)) && pad=1
    render_mini "${w}" "${pad}"
    return
  fi

  local cols=3 iw=$((CW - 2))
  pad=$(( (w - (cols * CW + (cols - 1) * GAP)) / 2 ))
  ((pad < 0)) && pad=0
  local sp gapsp
  printf -v sp '%*s' "${pad}" ''
  printf -v gapsp '%*s' "${GAP}" ''

  # 页眉：左边标题，右边齿轮设置入口（设置不占模块级，降到页眉里）
  local title=" bupty · 首页" gear="⚙ 设置 " fill
  w_of "${title}"; fill=$((w - pad - _CORE_W))
  w_of "${gear}"; fill=$((fill - _CORE_W))
  ((fill < 1)) && fill=1
  printf '%s%s%s%s%*s%s%s%s\n' "${sp}" "${C_ACC}" "${title}" "${R}" "${fill}" '' "${C_MUT}" "${gear}" "${R}"
  printf '%s%s\n' "${sp}" "$(hline $((w - pad)) "${C_BOR}")"

  local r i c idx
  for ((r = 0; r * cols < 6; r++)); do
    local -a cells=()
    for ((i = 0; i < cols; i++)); do
      idx=$((r * cols + i))
      ((idx < 6)) && cells+=("${idx}")
    done
    (( ${#cells[@]} == 0 )) && break

    local -a block=()
    for idx in "${cells[@]}"; do
      icon_render "${KEYS[$idx]}" "${COLORS[$idx]}"
      local bcol="${C_BOR}" tcol="${C_TXT}" markcol="${C_BOR}" top
      if ((idx == 1)); then
        # 选中态：边框提到强调色，左上角塞一个 ▶，名称加反显「药丸」。
        # 三种线索同时给，是因为单靠颜色在多主题/色弱下不够可靠。
        bcol="${C_ACC}"; tcol="${C_HL}"; markcol="${C_ACC}"
        # ┌ + ─ + ▶ + (iw-2) 个 ─ + ┐ = iw + 2，和非选中态等宽。
        # 注意是 iw-2 不是 iw-3：iw-3 会少 1 列，选中那行的右边框整体左移一格。
        top="${bcol}┌─${markcol}▶${R}${bcol}$(hline $((iw - 2)) "${bcol}")┐${R}"
      else
        top="${bcol}┌$(hline "${iw}" "${bcol}")┐${R}"
      fi
      block+=("${top}")
      block+=("$(card_row "${iw}" "${bcol}" "${ICON_ROWS[0]}" "${COLORS[$idx]}" "" "${tcol}")")
      block+=("$(card_row "${iw}" "${bcol}" "${ICON_ROWS[1]}" "${COLORS[$idx]}" "" "${tcol}")")
      block+=("$(card_row "${iw}" "${bcol}" "${ICON_ROWS[2]}" "${COLORS[$idx]}" "${LABELS[$idx]}" "${tcol}")")
      block+=("$(card_row "${iw}" "${bcol}" "${ICON_ROWS[3]}" "${COLORS[$idx]}" "${INFOS[$idx]}" "${C_MUT}")")
      block+=("$(card_row "${iw}" "${bcol}" "${ICON_ROWS[4]}" "${COLORS[$idx]}" "" "${tcol}")")
      block+=("$(card_row "${iw}" "${bcol}" "${ICON_ROWS[5]}" "${COLORS[$idx]}" "" "${tcol}")")
      block+=("${bcol}└$(hline "${iw}" "${bcol}")┘${R}")
    done

    for ((i = 0; i < CARD_H; i++)); do
      local out=""
      for ((c = 0; c < ${#cells[@]}; c++)); do
        ((c > 0)) && out+="${gapsp}"
        out+="${block[$((c * CARD_H + i))]}"
      done
      printf '%s%s\n' "${sp}" "${out}"
    done
    if (( (r + 1) * cols < 6 )); then printf '\n'; fi
  done
}

# 自检：任何一行都不得超过该宽度（响应式硬不变量）
#
# 量「带颜色的成品行」之前必须先剥掉 ANSI。_core_width 是「字符串占几列」的纯函数，
# 它会把 \033[38;5;244m 这种序列也当成可见字符算进去；终端则把转义当零宽。
#
# 千万别写成 ${s//$'\033'\[[0-9;]*[a-zA-Z]/} —— 看着对，实际是错的：
# bash 的 glob `*` 贪婪，会一路吞到行尾（行尾的 m 正好满足 [a-zA-Z]），
# 于是从第一个转义一直删到字符串末尾，**整行变空、宽度量成 0**，
# 自检就会「全部通过」而其实什么都没检查。下面用最短匹配（#）逐个剥，才可靠。
strip_ansi() {
  local s="$1" out=""
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"   # 转义之前的内容
    s="${s#*$'\033['}"       # 去掉「ESC[」
    s="${s#*[a-zA-Z]}"       # 去掉参数直到终止字母（# = 最短匹配）
  done
  printf '%s%s' "${out}" "${s}"
}

check_all() {
  local bad=0 w line n=0 plain ref nw first isgrid
  for w in 16 20 24 30 34 38 40 44 50 56 60 70 76 80 90 100 120 160 200; do
    ref=-1
    first=""
    while IFS= read -r line; do
      n=$((n + 1))
      plain="$(strip_ansi "${line}")"
      # 空行是分块用的，不参与检查
      [[ -z "${plain// /}" ]] && continue

      _core_width "${plain}"
      nw=${_CORE_W}

      # 不变量 1：任何一行都不得超过终端宽度（超了就会折行、整屏错乱）
      if (( nw > w )); then
        printf '溢出：宽度 %d 的一行实测 %d 列 → |%s|\n' "${w}" "${nw}" "${plain}"
        bad=$((bad + 1))
      fi

      # 不变量 2：卡片网格内所有行必须等宽。
      #
      # 只对「含边框字符」的行做等宽断言，是因为页眉/分隔线本来就铺满整行，
      # 而卡片网格是居中的固定宽度块 —— 两者宽度**本来就不该相等**。
      # 用「所有行都等宽」会得到一屏假报警，反而掩盖真问题。
      isgrid=0
      [[ "${plain}" == *┌* || "${plain}" == *│* || "${plain}" == *└* ]] && isgrid=1
      if (( isgrid )); then
        if (( ref < 0 )); then
          ref=${nw}; first="${plain}"
        elif (( nw != ref )); then
          printf '错位：宽度 %d 出现 %d 列的卡片行（基准 %d 列）\n  基准 |%s|\n  此行 |%s|\n' \
            "${w}" "${nw}" "${ref}" "${first}" "${plain}"
          bad=$((bad + 1))
        fi
      fi
    done < <(render "${w}")
  done
  printf '扫描 %d 行，问题 %d 处。\n' "${n}" "${bad}"
  return "$((bad > 0))"
}

# 反向对照：故意塞一个超宽行，确认 check_all 真的会失败。
# 不会失败的测试等于没测 —— 这个函数就是用来证明 check_all 不是摆设的。
check_selftest() {
  local bad=0
  # 造一个 81 列的行，在 80 列下必须被判溢出
  local wide
  printf -v wide '%*s' 81 ''
  _core_width "${wide}"
  if (( _CORE_W <= 80 )); then
    printf '反向对照失败：81 空格的宽度被量成 %d，宽度引擎有问题。\n' "${_CORE_W}"
    bad=1
  else
    printf '反向对照：81 空格在 80 列下正确判为 %d 列。\n' "${_CORE_W}"
  fi
  # strip 剥错的话，带色行的宽度会塌成 0，这里必须量出真实宽度
  _core_width "$(strip_ansi $'\033[38;5;244m▸\033[0m\033[38;5;252m 作业 DDL\033[0m')"
  if (( _CORE_W != 10 )); then
    printf '反向对照失败：带色行的可见宽度应为 10，实得 %d —— strip_ansi 坏了，本次自检无效。\n' "${_CORE_W}"
    bad=1
  else
    printf '反向对照：带色行剥离后宽度正确（10 列）。\n'
  fi
  return "${bad}"
}

if [[ "${2:-}" == "check" ]]; then
  check_selftest || exit 1
  check_all
  exit $?
fi
render "${W}"
