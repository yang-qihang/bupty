#!/usr/bin/env bash
# views/home.sh —— 首页模块卡片网格（响应式档位 A/B/C + 顶栏设置焦点）。
#
# 档位阶梯（宽度不足逐级退化，任何一行都不得超过 UI_COLS）：
#   A 卡片   3 列 × 2 行，卡片 25×8，需要 UI_COLS >= 79 且 UI_ROWS-5 >= 17
#   B 迷你卡 2 列 × 3 行，每张 3 行，需要 40 <= UI_COLS < 79 且 UI_ROWS-5 >= 11
#   C 紧凑行 1 列 × 6 行，UI_COLS < 40 或高度不足
# 说明：档位 A 的几何是 3×25 + 2×2 = 79 列，所以 A 的宽度阈值是 79 而不是 76
# （76~78 列放不下三张 25 列卡片会溢出）。以几何公式为准，宁可提前退化。

# 六个模块，顺序固定（与 lib/icons.sh 的 ICON_KEYS 一致）。
HOME_KEYS=(assignments schedule classrooms grades exams public)
HOME_NAMES=("作业 DDL" "课表" "空教室" "成绩" "考试" "公共查询")
# 卡片右侧短描述（非实时数据；每项 ≤ 9 列，保证档位 A 文本区放得下）。
HOME_INFOS=("待办截止" "本周课表" "空闲教室" "学期绩点" "考试安排" "常用入口")
# 模块配色角色名（唯一配色常量，渲染时映射到主题变量，不要散落颜色）。
HOME_COLOR_ROLES=(danger accent success purple warning accent)

# 焦点状态：设置不占模块级下标，单独用 HOME_FOCUS 表达 grid/settings。
HOME_SEL=0        # 模块下标 0..5
HOME_FOCUS="grid" # grid | settings

# 当前模块是否被选中（设置焦点时网格里没有选中项）。
_home_is_selected() {
  [[ "${HOME_FOCUS}" == "grid" && "${HOME_SEL}" == "$1" ]]
}

# 计算当前档位与列数，结果写全局 _HOME_TIER / _HOME_COLS。
_home_layout() {
  local body=$((UI_ROWS - 5))
  if (( UI_COLS >= 79 && body >= 17 )); then
    _HOME_TIER='A'
    _HOME_COLS=3
  elif (( UI_COLS >= 40 && body >= 11 )); then
    _HOME_TIER='B'
    _HOME_COLS=2
  else
    _HOME_TIER='C'
    _HOME_COLS=1
  fi
}

# 把配色角色名常量映射成当前主题的 SGR 数组（每帧一次，零 fork）。
_home_palette() {
  local role
  _HOME_PALETTE=()
  for role in "${HOME_COLOR_ROLES[@]}"; do
    case "${role}" in
      danger) _HOME_PALETTE+=("${UI_DANGER}") ;;
      accent) _HOME_PALETTE+=("${UI_ACCENT}") ;;
      success) _HOME_PALETTE+=("${UI_SUCCESS}") ;;
      purple) _HOME_PALETTE+=("${UI_PURPLE}") ;;
      warning) _HOME_PALETTE+=("${UI_WARNING}") ;;
      *) _HOME_PALETTE+=("${UI_ACCENT}") ;;
    esac
  done
}

# 把 <文本> 补齐到 <宽度> 列（超宽整字符截断），结果写全局 _HOME_FIT。
# 走 _core_width 零 fork 快路径；仅超宽时用 core_fit 兜底（当前常量不会超宽）。
_home_fit() {
  local s="${1:-}" w="${2:-0}"
  (( w < 0 )) && w=0
  _core_width "${s}"
  if (( _CORE_W > w )); then
    _HOME_FIT="$(core_fit "${s}" "${w}")"
  else
    printf -v _HOME_FIT '%s%*s' "${s}" "$((w - _CORE_W))" ''
  fi
}

# 渲染一张档位 A 卡片的 8 行到全局 _HOME_CARD_ROWS。
# <hline_sel> 是选中卡片顶边里 ▶ 之后那一段横线，根数由 _home_render_cards 按列数反推。
_home_card_a_rows() {
  local idx="$1" hline="$2" hline_sel="$3" tw="$4"
  local bcol tcol name info name_fit info_fit blank_fit top
  if _home_is_selected "${idx}"; then
    bcol="${UI_ACCENT}"; tcol="${UI_HL_FG}"
  else
    bcol="${UI_BORDER}"; tcol="${UI_TEXT}"
  fi
  name="${HOME_NAMES[$idx]}"
  info="${HOME_INFOS[$idx]}"
  _home_fit "${name}" "${tw}"; name_fit="${_HOME_FIT}"
  _home_fit "${info}" "${tw}"; info_fit="${_HOME_FIT}"
  _home_fit "" "${tw}"; blank_fit="${_HOME_FIT}"

  icon_render "${HOME_KEYS[$idx]}" "${_HOME_PALETTE[$idx]}"

  # 选中态三线索:顶边框左上角 ▶ 标记 + 边框提亮 + 名称反显。
  # 宽度与未选中严格相等——见 _home_render_cards 里按列数反推横线根数的说明。
  if _home_is_selected "${idx}"; then
    top="${bcol}${_UI_BOX_TL}${_UI_BOX_H}▶${hline_sel}${_UI_BOX_TR}${UI_RESET}"
  else
    top="${bcol}${_UI_BOX_TL}${hline}${_UI_BOX_TR}${UI_RESET}"
  fi

  _HOME_CARD_ROWS=()
  _HOME_CARD_ROWS+=("${top}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_V}${UI_RESET}${ICON_ROWS[0]}  ${tcol}${blank_fit}${UI_RESET}${bcol}${_UI_BOX_V}${UI_RESET}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_V}${UI_RESET}${ICON_ROWS[1]}  ${tcol}${blank_fit}${UI_RESET}${bcol}${_UI_BOX_V}${UI_RESET}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_V}${UI_RESET}${ICON_ROWS[2]}  ${tcol}${name_fit}${UI_RESET}${bcol}${_UI_BOX_V}${UI_RESET}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_V}${UI_RESET}${ICON_ROWS[3]}  ${UI_MUTED}${info_fit}${UI_RESET}${bcol}${_UI_BOX_V}${UI_RESET}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_V}${UI_RESET}${ICON_ROWS[4]}  ${tcol}${blank_fit}${UI_RESET}${bcol}${_UI_BOX_V}${UI_RESET}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_V}${UI_RESET}${ICON_ROWS[5]}  ${tcol}${blank_fit}${UI_RESET}${bcol}${_UI_BOX_V}${UI_RESET}")
  _HOME_CARD_ROWS+=("${bcol}${_UI_BOX_BL}${hline}${_UI_BOX_BR}${UI_RESET}")
}

# 档位 A：3 列 × 2 行卡片，卡片 25 列 × 8 行。
_home_render_cards() {
  local CW=25 GAP=2 CARD_H=8 TW=9
  local pad=$(( (UI_COLS - (3 * CW + 2 * GAP)) / 2 ))
  (( pad < 0 )) && pad=0
  local padstr gapstr hline hline_sel i
  printf -v padstr '%*s' "${pad}" ''
  printf -v gapstr '%*s' "${GAP}" ''

  # 横线根数必须按**显示列数**反推，不能写死 IW / IW-2。
  # 原因：▶（U+25B6）属于 East Asian Ambiguous 宽度类，在 CJK 终端（BUPTY_AMBIG_W=2）
  # 下实占 2 列；而那种配置下 icon_init 会推出 ICON_UNICODE_W=2，ui_box_init 随之把边框
  # 退成 ASCII 的 '-'（1 列）。于是「▶ 与横线等宽」这个前提不再成立，写死 IW-2 会让选中
  # 卡片的顶边比别的卡片宽 1 列，整行顶出右边界（79 列终端上恰好 80 列）。
  # 按列数反推后两种配置都精确等于 CW 列；BUPTY_AMBIG_W=1 时结果与旧实现逐字节相同。
  local cwd hw mw
  _core_width "${_UI_BOX_TL}"; cwd="${_CORE_W}"
  _core_width "${_UI_BOX_H}"; hw="${_CORE_W}"
  _core_width '▶'; mw="${_CORE_W}"
  (( hw < 1 )) && hw=1
  local n_plain=$(( (CW - 2 * cwd) / hw ))
  local n_sel=$(( (CW - 2 * cwd - hw - mw) / hw ))
  (( n_plain < 0 )) && n_plain=0
  (( n_sel < 0 )) && n_sel=0
  hline=""
  for ((i = 0; i < n_plain; i++)); do hline+="${_UI_BOX_H}"; done
  hline_sel=""
  for ((i = 0; i < n_sel; i++)); do hline_sel+="${_UI_BOX_H}"; done

  local -a cells blk
  local r c idx l line
  for ((r = 0; r < 2; r++)); do
    cells=()
    for ((c = 0; c < 3; c++)); do
      idx=$((r * 3 + c))
      (( idx < 6 )) && cells+=("${idx}")
    done
    blk=()
    for idx in "${cells[@]}"; do
      _home_card_a_rows "${idx}" "${hline}" "${hline_sel}" "${TW}"
      blk+=("${_HOME_CARD_ROWS[@]}")
    done
    for ((l = 0; l < CARD_H; l++)); do
      line=""
      for ((c = 0; c < ${#cells[@]}; c++)); do
        (( c > 0 )) && line+="${gapstr}"
        line+="${blk[$((c * CARD_H + l))]}"
      done
      printf '%s%s\n' "${padstr}" "${line}"
    done
    # 两行卡片之间空一行。
    (( r == 0 )) && printf '\n'
  done
}

# 渲染一张档位 B 迷你卡（3 行）到全局 _HOME_MINI_BLOCK。
_home_mini_card() {
  local idx="$1" iw="$2" hline="$3"
  local bcol tcol mark mcol nm info line line_w info_w rest mid
  if _home_is_selected "${idx}"; then
    bcol="${UI_ACCENT}"; tcol="${UI_HL_FG}"; mark="▶"; mcol="${UI_ACCENT}"
  else
    bcol="${UI_BORDER}"; tcol="${UI_TEXT}"; mark="▸"; mcol="${UI_MUTED}"
  fi
  nm=" ${HOME_NAMES[$idx]}"
  info="${HOME_INFOS[$idx]}"
  line="${mark}${nm}"
  _core_width "${line}"; line_w="${_CORE_W}"
  _core_width "${info}"; info_w="${_CORE_W}"
  rest=$(( iw - line_w - info_w ))

  _HOME_MINI_BLOCK=()
  _HOME_MINI_BLOCK+=("${bcol}${_UI_BOX_TL}${hline}${_UI_BOX_TR}${UI_RESET}")
  if (( rest >= 2 )); then
    printf -v mid '%*s' "$((rest - 1))" ''
    _HOME_MINI_BLOCK+=("${bcol}${_UI_BOX_V}${UI_RESET}${mcol}${mark}${UI_RESET}${tcol}${nm}${UI_RESET}${mid}${UI_MUTED}${info}${UI_RESET} ${bcol}${_UI_BOX_V}${UI_RESET}")
  else
    # 负宽度必须自己钳到 0：printf '%*s' 的宽度为正数才是「补齐 N 个空格」，
    # 传负数会按左对齐处理、照样输出 |负数| 个空格——即越界时不是缩窄而是**再加宽**。
    # 当前常量下 rest < 2 时 iw - line_w 仍为正（line_w 最大 10、iw 最小 16），
    # 但模块名一旦变长就会踩到，这里显式防守。
    local pad_w=$(( iw - line_w ))
    (( pad_w < 0 )) && pad_w=0
    printf -v mid '%*s' "${pad_w}" ''
    _HOME_MINI_BLOCK+=("${bcol}${_UI_BOX_V}${UI_RESET}${mcol}${mark}${UI_RESET}${tcol}${nm}${UI_RESET}${mid}${bcol}${_UI_BOX_V}${UI_RESET}")
  fi
  _HOME_MINI_BLOCK+=("${bcol}${_UI_BOX_BL}${hline}${_UI_BOX_BR}${UI_RESET}")
}

# 档位 B：2 列 × 3 行迷你卡，无图标，每张 3 行。
_home_render_mini() {
  local GAP=2
  local pad=$(( (UI_COLS - (2 * 24 + 2)) / 2 ))
  (( pad < 1 )) && pad=1
  local cw=$(( (UI_COLS - pad - GAP) / 2 ))
  local iw=$((cw - 2))
  (( iw < 1 )) && iw=1
  local padstr gapstr hline i
  printf -v padstr '%*s' "${pad}" ''
  printf -v gapstr '%*s' "${GAP}" ''
  hline=""
  for ((i = 0; i < iw; i++)); do hline+="${_UI_BOX_H}"; done

  local -a block
  local row idx l
  for ((row = 0; row < 3; row++)); do
    block=()
    for ((idx = row * 2; idx < row * 2 + 2; idx++)); do
      _home_mini_card "${idx}" "${iw}" "${hline}"
      block+=("${_HOME_MINI_BLOCK[@]}")
    done
    for ((l = 0; l < 3; l++)); do
      printf '%s%s%s%s\n' "${padstr}" "${block[$l]}" "${gapstr}" "${block[$((3 + l))]}"
    done
    (( row < 2 )) && printf '\n'
  done
}

# 档位 C：1 列紧凑行。这是 UI_COLS < 40 的兜底档，没有任何宽度/高度下限，
# 因此这里必须自己把两条硬不变量撑住（见 docs/ARCHITECTURE.md）：
#   * 每行 <= UI_COLS —— 极窄时把模块名也截断（此前名字不参与预算，UI_COLS <= 9 必溢出）
#   * 帧高 <= UI_ROWS - 5 —— 极矮时按滑动窗口只渲染选中项所在的一段
_home_render_list() {
  local pad=0
  (( UI_COLS > 24 )) && pad=1
  local padstr
  printf -v padstr '%*s' "${pad}" ''
  local budget=$(( UI_COLS - pad ))
  (( budget < 0 )) && budget=0

  # 行窗口：可见行数不超过正文高度，且选中项必须落在窗口内（窗口口径同设置页）。
  # 高度不足时不强行渲染——UI_ROWS <= 5 时正文预算为 0，多画一行就会把帧顶穿。
  local total=6 body=$(( UI_ROWS - 5 ))
  (( body < 0 )) && body=0
  local visible="${body}"
  (( visible > total )) && visible="${total}"
  local offset=0
  if (( visible > 0 )); then
    if (( HOME_SEL >= visible )); then offset=$(( HOME_SEL - visible + 1 )); fi
    if (( offset > total - visible )); then offset=$(( total - visible )); fi
    (( offset < 0 )) && offset=0
  fi
  local end=$(( offset + visible ))
  (( end > total )) && end="${total}"

  local i mark mcol txt info line line_w info_w rest mark_w name_budget
  for ((i = offset; i < end; i++)); do
    if _home_is_selected "${i}"; then
      mark="▶"; mcol="${UI_ACCENT}"
    else
      mark="▸"; mcol="${UI_MUTED}"
    fi
    txt=" ${HOME_NAMES[$i]}"
    info="${HOME_INFOS[$i]}"
    line="${mark}${txt}"
    _core_width "${line}"; line_w="${_CORE_W}"
    # 极窄终端：连「标记 + 名称」都超预算时，名称也要让位，否则整行顶出右边界。
    # 只在真的超预算时才截断——core_fit 会补齐空格，无脑套用会改变宽终端下的原有间距。
    if (( line_w > budget )); then
      _core_width "${mark}"; mark_w="${_CORE_W}"
      name_budget=$(( budget - mark_w ))
      (( name_budget < 0 )) && name_budget=0
      txt="$(core_fit "${HOME_NAMES[$i]}" "${name_budget}")"
      line="${mark}${txt}"
      _core_width "${line}"; line_w="${_CORE_W}"
      # 连标记自己都放不下：▶(U+25B6) 在 amb=2 下实占 2 列，终端只剩 1 列时
      # 保留标记等于把整行钉死在 2 列。丢掉标记，只留截断后的正文（同设置页做法）。
      if (( line_w > budget )); then
        mark=""; mcol=""
        line="${txt}"
        _core_width "${line}"; line_w="${_CORE_W}"
      fi
    fi
    _core_width "${info}"; info_w="${_CORE_W}"
    rest=$(( budget - line_w - info_w - 2 ))
    printf '%s' "${padstr}"
    if [[ -n "${mark}" ]]; then
      printf '%s%s%s' "${mcol}" "${mark}" "${UI_RESET}"
    fi
    printf '%s%s%s' "${UI_TEXT}" "${txt}" "${UI_RESET}"
    if (( rest >= 1 )); then
      printf '%*s' "${rest}" ''
      printf '%s%s%s' "${UI_MUTED}" "${info}" "${UI_RESET}"
    fi
    printf '\n'
  done
}

render_home() {
  _home_layout
  _home_palette
  case "${_HOME_TIER}" in
    A) _home_render_cards ;;
    B) _home_render_mini ;;
    *) _home_render_list ;;
  esac
}

# 垂直移动（上=-1 / 下=+1）：尽量保持列号，目标行较短时落到该行最后一个。
_home_move_vertical() {
  local delta="$1" cols="${_HOME_COLS}" total="${#HOME_KEYS[@]}"
  local row col rows nr ncol nc
  row=$((HOME_SEL / cols))
  col=$((HOME_SEL % cols))
  rows=$(( (total + cols - 1) / cols ))
  nr=$((row + delta))
  if (( nr < 0 || nr >= rows )); then
    return 1
  fi
  ncol=$(( total - nr * cols ))
  (( ncol > cols )) && ncol=${cols}
  (( ncol < 1 )) && ncol=1
  nc=${col}
  (( nc >= ncol )) && nc=$((ncol - 1))
  HOME_SEL=$(( nr * cols + nc ))
  return 0
}

handle_home_key() {
  local key="$1" cols row col
  _home_layout
  cols="${_HOME_COLS}"
  case "${key}" in
    ENTER)
      if [[ "${HOME_FOCUS}" == "settings" ]]; then
        tui_switch settings
      else
        tui_switch "${HOME_KEYS[$HOME_SEL]}"
      fi
      # 离开首页时焦点复位到网格，避免下次回来还停在设置上。
      HOME_FOCUS="grid"
      ;;
    UP)
      if [[ "${HOME_FOCUS}" == "settings" ]]; then
        return 0
      fi
      row=$((HOME_SEL / cols))
      if (( row == 0 )); then
        # 第一行再按 ↑：焦点移到顶栏的 ⚙ 设置。
        HOME_FOCUS="settings"
      else
        _home_move_vertical -1
      fi
      ;;
    DOWN)
      if [[ "${HOME_FOCUS}" == "settings" ]]; then
        # 设置焦点上的返回键是 DOWN（ESC 被 tui_main 的 tui_back 截走，到不了这里）。
        HOME_FOCUS="grid"
      else
        _home_move_vertical 1 || true
      fi
      ;;
    LEFT)
      [[ "${HOME_FOCUS}" == "grid" ]] || return 0
      col=$((HOME_SEL % cols))
      (( col > 0 )) && (( HOME_SEL -= 1 ))
      ;;
    RIGHT)
      [[ "${HOME_FOCUS}" == "grid" ]] || return 0
      col=$((HOME_SEL % cols))
      if (( col < cols - 1 && HOME_SEL < ${#HOME_KEYS[@]} - 1 )); then
        (( HOME_SEL += 1 ))
      fi
      ;;
  esac
}
