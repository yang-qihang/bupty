#!/usr/bin/env bash
# views/home.sh —— 首页模块卡片网格（响应式档位 A/B/C/D + 顶栏设置焦点）。
#
# 版式（3+3+1）：**单一 3 列栅格**，栅格宽 79 列 = 3×25 + 2×2 间隙，整体水平居中。
#   行 1 = 3 张卡（0,1,2）／空 1 行／行 2 = 3 张卡（3,4,5）／空 1 行／行 3 = 1 张卡（6）
#   第 3 行只有一张，**靠左**与上面两行的第 1 列对齐，不居中。
#
# 栅格末行空出来的格子补**装饰卡框**（_home_decor_rows）：与真卡同尺寸、同边框字符集，
# 但整框走 UI_MUTED（明显更暗）、内部只在正中放一个「…」当预留位暗示。装饰框不可选中
# （不参与 HOME_SEL / _home_pos，没有 ▶/▸ 标记，也没有任何选中态），纯为版面完整。
#   档 A 行 3 = 图标卡 6 + 2 个 8 行装饰框；档 B 行 3 = 迷你卡 6 + 2 个 3 行装饰框；
#   档 C 第 4 行 = 迷你卡 6 + 1 个 3 行装饰框；档 D 是列表、没有栅格，不画。
#
# 档位阶梯（宽度或高度不足逐级退化，任何一行都不得超过 UI_COLS）：
#   正文可用行数 body = UI_ROWS - chrome；chrome 由 banner_chrome_rows **唯一**给出，
#   本文件不自己算 chrome（顶栏加页签条、大字符块开关都会改它），阈值一律写成 body 条件。
#   A  7 张**全走图标卡**（每张 25×8）：8+1+8+1+8 = 26 行；需要 UI_COLS >= 79 且 body >= 26
#   B  前 3 张图标卡、后 4 张迷你卡（每张 25×3）：行 2 换成 3 张迷你卡、行 3 换成 1 张迷你卡，
#      仍是同一个 3+3+1 形状：8+1+3+1+3 = 16 行；需要 UI_COLS >= 79 且 body >= 16
#   C  7 张全部走迷你卡，2 列 × 4 行 = 15 行；需要 40 <= UI_COLS 且 body >= 15
#   D  1 列 × 7 行紧凑行（按正文高度开滑动窗口）；UI_COLS < 40 或高度不足
# 选档顺序：取**满足条件的最高档**（A → B → C → D）；A 的阈值严格强于 B 的阈值。
# 说明（阈值一律从几何反推，宁可提前退化）：
#   * 3 列栅格的几何是 3×25 + 2×2 = 79 列，所以放得下 3 列栅格的宽度下限是 79
#     （行 1/2/3 的卡片同宽 25，栅格整体居中；行 3 只有 1 张，仍贴在第 1 列）；
#   * 高度阈值 26 / 16 / 15 分别是三种版式算出来的定值，不是拍脑袋的经验数。
#
# 主次表达：A 档下 7 张全带图标；高度不够时先牺牲行 2、行 3 的图标（降成迷你卡，
# 省下 10 行），而不是把行 1 挤成 4 张、把图标压小。
# 第 7 张卡（研讨间）的图标同样走 icon_render "${HOME_KEYS[6]}"（booking 键已在
# lib/icons.sh 的 ICON_KEYS 里，本文件不去改它）。键缺失时 icon_render 会给 6 行空格
# 并返回 1——调用点都在 `|| true` 保护下（tui.sh 的 render_${TUI_VIEW}），不会炸，
# 所以这里按正常调用写，不加特判。
#
# 顶栏：第 7 个模块就是研讨间（booking，见 HOME_KEYS），它走的是上面这套栅格；
# 顶栏的页签条（含「研讨间」）由 lib/banner.sh + tui.sh 的 TUI_TABS 统一负责，本文件不感知。
# 设置不占模块下标，仍走顶栏 ⚙ 焦点（HOME_FOCUS）。

# 七个模块，顺序固定。档位 A 下七张都走带图标的卡片；档位 B/C 下只有前三个
# （assignments/schedule/classrooms，与 lib/icons.sh 的 ICON_KEYS 前三个一一对应）
# 还带图标，后四个降成无图标迷你卡。
HOME_KEYS=(assignments schedule classrooms grades exams public booking)
HOME_NAMES=("作业 DDL" "课表" "空教室" "成绩" "考试" "公共查询" "研讨间")
# 卡片右侧短描述（非实时数据；每项 ≤ 9 列，保证图标卡 9 列的文本区放得下）。
HOME_INFOS=("待办截止" "本周课表" "空闲教室" "学期绩点" "考试安排" "常用入口" "研讨预约")
# 模块配色角色名（唯一配色常量，渲染时映射到主题变量，不要散落颜色）。
# 只有图标卡用得上（档位 A 的 7 张、档位 B 的前 3 张）；迷你卡走 _home_mini_card，
# 不含模块色。共 7 项，与 HOME_KEYS 一一对应。
HOME_COLOR_ROLES=(danger accent success purple warning accent danger)

# 焦点状态：设置不占模块级下标，单独用 HOME_FOCUS 表达 grid/settings。
HOME_SEL=0        # 模块下标 0..6
HOME_FOCUS="grid" # grid | settings

# 当前模块是否被选中（设置焦点时网格里没有选中项）。
_home_is_selected() {
  [[ "${HOME_FOCUS}" == "grid" && "${HOME_SEL}" == "$1" ]]
}

# 计算当前档位与列数，结果写全局 _HOME_TIER / _HOME_COLS。
# _HOME_TIER ∈ {A, B, C, D}；_HOME_COLS 是该档位下**单行最多的格数**
# （A=3、B=3、C=2、D=1），只作信息用——导航不依赖它，而是查 _HOME_ROWS
# （档位 A/B 的行是 3/3/1：末行只有 1 格，任何 ±列数 的硬编码都是错的）。
# 正文可用行数：显式传入（tui_render 已经按 chrome 口径算好）优先；
# 否则按唯一口径 banner_chrome_rows 推导（首页出块时 11、否则 5）。
# 阈值一律从几何反推（见文件头的档位阶梯）：A=26 行、B=16 行、C=15 行。
_home_layout() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows home
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      # banner.sh 未被加载（docs/palette-lab.sh 单独 source 本文件）：块必然不显示。
      body=$(( UI_ROWS - 5 ))
    fi
  fi
  (( body < 0 )) && body=0
  if (( UI_COLS >= 79 && body >= 26 )); then
    _HOME_TIER='A'
    _HOME_COLS=3
  elif (( UI_COLS >= 79 && body >= 16 )); then
    _HOME_TIER='B'
    _HOME_COLS=3
  elif (( UI_COLS >= 40 && body >= 15 )); then
    _HOME_TIER='C'
    _HOME_COLS=2
  else
    _HOME_TIER='D'
    _HOME_COLS=1
  fi
}

# 当前档位下每一行的格数（按 HOME_KEYS 顺序从左到右、从上到下铺）。
# 这是**唯一**的行划分口径：渲染与导航都从这里取，不许各自再硬编码一遍。
# 档位 A/B 版式完全相同（3+3+1），只是卡的种类不同，所以行划分也完全一样。
_home_row_sizes() {
  case "${_HOME_TIER}" in
    A|B) _HOME_ROWS=(3 3 1) ;;   # 3+3+1 栅格：行 3 只有第 1 列
    C) _HOME_ROWS=(2 2 2 1) ;;   # 7 张迷你卡 2 列 × 4 行（末行只有 1 张）
    *) _HOME_ROWS=(1 1 1 1 1 1 1) ;;
  esac
}

# 由 HOME_SEL 反推所在行与行内列号，结果写 _HOME_ROW / _HOME_INROW。
_home_pos() {
  _home_row_sizes
  local i start=0 n
  for i in "${!_HOME_ROWS[@]}"; do
    n="${_HOME_ROWS[$i]}"
    if (( HOME_SEL < start + n )); then
      _HOME_ROW="${i}"
      _HOME_INROW=$(( HOME_SEL - start ))
      return 0
    fi
    start=$(( start + n ))
  done
  # 下标越界（不该发生）：夹到最后一行最后一格。
  _HOME_ROW=$(( ${#_HOME_ROWS[@]} - 1 ))
  _HOME_INROW=$(( _HOME_ROWS[_HOME_ROW] - 1 ))
  return 0
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

# 渲染一张图标卡（档位 A 的 7 张 / 档位 B 的前 3 张）的 8 行到全局 _HOME_CARD_ROWS。
# <hline_sel> 是选中卡片顶边里 ▶ 之后那一段横线，根数由 _home_render_cards 按列数反推。
_home_card_a_rows() {
  local idx="$1" hline="$2" hline_sel="$3" tw="$4"
  local bcol tcol name info name_fit info_fit blank_fit top
  if _home_is_selected "${idx}"; then
    bcol="${UI_ACCENT}"; tcol="${UI_SEL}"
  else
    bcol="${UI_BORDER}"; tcol="${UI_TEXT}"
  fi
  name="${HOME_NAMES[$idx]}"
  info="${HOME_INFOS[$idx]}"
  _home_fit "${name}" "${tw}"; name_fit="${_HOME_FIT}"
  _home_fit "${info}" "${tw}"; info_fit="${_HOME_FIT}"
  _home_fit "" "${tw}"; blank_fit="${_HOME_FIT}"

  icon_render "${HOME_KEYS[$idx]}" "${_HOME_PALETTE[$idx]}" "${UI_RESET}"

  # 选中态三线索:顶边框左上角 ▶ 标记 + 边框提亮 + 名称提亮。
  # 名称用 UI_SEL（纯前景、**不含背景**）；绝不能用 UI_HL_FG 当纯前景色——它带
  # 48;5; 背景，曾把选中卡右侧 9 列文本区刷成一块游离蓝底（且描述行用 UI_MUTED，
  # 那块蓝中间还破了个洞）。描述行维持 UI_MUTED（次要信息），因为现在整张卡片
  # 没有任何背景色，「一致」体现在没有游离色块，而不是全行同色。
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

# 渲染一个**装饰卡框**（末行空位的占位框，不可选中）到全局 _HOME_DECOR_BLOCK：
# 共 <card_h> 行、宽 <cw> 列（== 真.card 尺寸），<hline> 是内宽 (cw-2) 的横线串。
#   * 边框字符集与真卡**完全相同**（_UI_BOX_*），但整框走 UI_MUTED（比真卡明显更暗）；
#   * 内部留空，只在正中一行放一个「…」暗示这里预留了位置（未来可能新增入口）；
#   * 没有 ▶/▸ 焦点标记，不参与 HOME_SEL / _home_pos，也没有任何选中/悬停态。
# 宽度一律交内核：…（U+2026）属 East Asian Ambiguous 类，amb=1 占 1 列、amb=2 占 2 列，
# 所以居中偏移与补齐都走 _core_width + _core_fit_compute（禁止用 ${#s} 数字符数）。
# 每行都以 UI_RESET（复位 + 本主题底色）收尾，保持「帧内复位后紧跟底色 SGR」的不变量。
_home_decor_rows() {
  local cw="$1" card_h="$2" hline="$3"
  local iw=$(( cw - 2 ))
  (( iw < 1 )) && iw=1
  local mid=$(( card_h / 2 ))   # 8 行 → 第 5 行；3 行 → 中间那行
  _core_width '…'; local lw="${_CORE_W}"
  local left=$(( (iw - lw) / 2 ))
  (( left < 0 )) && left=0
  local right=$(( iw - lw - left ))
  (( right < 0 )) && right=0
  local inner blank
  # 先按 ……落位、再用 _core_fit_compute 兜一次：保证正好 iw 列（超宽时整字符截断，
  # 绝不会顶破边框——iw 最小 16 时两种 amb 档都有富余，这里是防御性写法）。
  printf -v inner '%*s…%*s' "${left}" '' "${right}" ''
  _core_fit_compute "${inner}" "${iw}"
  inner="${_CORE_FIT_OUT}"
  _core_fit_compute '' "${iw}"
  blank="${_CORE_FIT_OUT}"

  _HOME_DECOR_BLOCK=()
  _HOME_DECOR_BLOCK+=("${UI_MUTED}${_UI_BOX_TL}${hline}${_UI_BOX_TR}${UI_RESET}")
  local i
  for ((i = 1; i < card_h - 1; i++)); do
    if (( i == mid )); then
      _HOME_DECOR_BLOCK+=("${UI_MUTED}${_UI_BOX_V}${inner}${_UI_BOX_V}${UI_RESET}")
    else
      _HOME_DECOR_BLOCK+=("${UI_MUTED}${_UI_BOX_V}${blank}${_UI_BOX_V}${UI_RESET}")
    fi
  done
  _HOME_DECOR_BLOCK+=("${UI_MUTED}${_UI_BOX_BL}${hline}${_UI_BOX_BR}${UI_RESET}")
}

# 渲染一行图标卡到 stdout（每行带左内边距 padstr、卡间 GAP 列，行尾都有换行）。
#   参数：<起始下标> <张数> <卡宽> <卡高> <文本宽> <横线> <选中横线> <左内边距串> <间隙串> [<装饰框数>]
# 每张卡逐张调 _home_card_a_rows（产出卡高行），再横向拼成整行；行尾可跟 <装饰框数> 个
# 同尺寸的装饰卡框（补末行空位，见 _home_decor_rows）。
_home_icon_row() {
  local start="$1" n="$2" cw="$3" card_h="$4" tw="$5"
  local hline="$6" hline_sel="$7" padstr="$8" gapstr="$9"
  local decor="${10:-0}"
  local -a blk=()
  local i idx l line
  for ((i = 0; i < n; i++)); do
    idx=$(( start + i ))
    _home_card_a_rows "${idx}" "${hline}" "${hline_sel}" "${tw}"
    blk+=("${_HOME_CARD_ROWS[@]}")
  done
  for ((i = 0; i < decor; i++)); do
    _home_decor_rows "${cw}" "${card_h}" "${hline}"
    blk+=("${_HOME_DECOR_BLOCK[@]}")
  done
  local ncells=$(( n + decor ))
  for ((l = 0; l < card_h; l++)); do
    line=""
    for ((i = 0; i < ncells; i++)); do
      (( i > 0 )) && line+="${gapstr}"
      line+="${blk[$((i * card_h + l))]}"
    done
    printf '%s%s\n' "${padstr}" "${line}"
  done
}

# 渲染一行迷你卡到 stdout（每张 3 行 / 宽 cw，卡间 GAP 列，行首 padstr，行尾换行）。
#   参数：<起始下标> <张数> <卡宽> <左内边距串> <间隙串> [<装饰框数>]
# 宽度固定为 cw（同栅格里每张一样宽），因此能和上面的图标卡严格同列对齐；
# 行尾可跟 <装饰框数> 个同尺寸（cw×3）的装饰卡框（补末行空位，见 _home_decor_rows）。
_home_mini_row() {
  local start="$1" n="$2" cw="$3" padstr="$4" gapstr="$5"
  local decor="${6:-0}"
  local iw=$(( cw - 2 ))
  (( iw < 1 )) && iw=1
  local hline="" i idx l line
  for ((i = 0; i < iw; i++)); do hline+="${_UI_BOX_H}"; done
  local -a blk=()
  for ((i = 0; i < n; i++)); do
    idx=$(( start + i ))
    _home_mini_card "${idx}" "${iw}" "${hline}"
    blk+=("${_HOME_MINI_BLOCK[@]}")
  done
  for ((i = 0; i < decor; i++)); do
    _home_decor_rows "${cw}" 3 "${hline}"
    blk+=("${_HOME_DECOR_BLOCK[@]}")
  done
  local ncells=$(( n + decor ))
  for ((l = 0; l < 3; l++)); do
    line=""
    for ((i = 0; i < ncells; i++)); do
      (( i > 0 )) && line+="${gapstr}"
      line+="${blk[$((i * 3 + l))]}"
    done
    printf '%s%s\n' "${padstr}" "${line}"
  done
}

# 档位 A / B 的正文：同一个 3+3+1 栅格（3×25 + 2×2 间隙 = 79 列，整体水平居中）。
#   行 1：图标卡 0,1,2（8 行）
#   空 1 行
#   行 2：档位 A 是图标卡 3,4,5（8 行）；档位 B 降成迷你卡 3,4,5（3 行）
#   空 1 行
#   行 3：卡 6 一张，**靠左**贴栅格第 1 列（与上面两行的第 1 列对齐，不居中）；
#         它右边空出来的 2 格补 2 个**装饰卡框**（同尺寸、不可选中，见 _home_decor_rows）
# 两种档位共用同一个渲染器，差别只在行 2 / 行 3 的卡种类（必须已经调过 _home_layout）。
# 兼容约束：docs/palette-lab.sh 的档位分支按**函数名**调 _home_render_cards
# （那个文件本分支不允许改），让它渲染整个档位正文，预览工具在默认 100 列下才还是完整首页。
_home_render_cards() {
  local CW=25 GAP=2 CARD_H=8 TW=9
  local grid_w=$(( 3 * CW + 2 * GAP ))
  local pad=$(( (UI_COLS - grid_w) / 2 ))
  (( pad < 0 )) && pad=0
  local padstr gapstr
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
  local hline="" hline_sel="" i
  for ((i = 0; i < n_plain; i++)); do hline+="${_UI_BOX_H}"; done
  for ((i = 0; i < n_sel; i++)); do hline_sel+="${_UI_BOX_H}"; done

  # 行 1：3 张图标卡。
  _home_icon_row 0 3 "${CW}" "${CARD_H}" "${TW}" "${hline}" "${hline_sel}" "${padstr}" "${gapstr}"
  printf '\n'
  # 行 2：档位 A 继续 3 张图标卡；档位 B 高度不够，先牺牲这一行的图标（降成迷你卡）。
  if [[ "${_HOME_TIER}" == "A" ]]; then
    _home_icon_row 3 3 "${CW}" "${CARD_H}" "${TW}" "${hline}" "${hline_sel}" "${padstr}" "${gapstr}"
  else
    _home_mini_row 3 3 "${CW}" "${padstr}" "${gapstr}"
  fi
  printf '\n'
  # 行 3：只剩 1 张真卡（下标 6），贴在栅格第 1 列——只加左内边距，不额外居中；
  #       右边空出来的 2 格补装饰卡框（同尺寸、不同色、不可选中）。
  if [[ "${_HOME_TIER}" == "A" ]]; then
    _home_icon_row 6 1 "${CW}" "${CARD_H}" "${TW}" "${hline}" "${hline_sel}" "${padstr}" "${gapstr}" 2
  else
    _home_mini_row 6 1 "${CW}" "${padstr}" "${gapstr}" 2
  fi
}

# 渲染一张迷你卡（3 行）到全局 _HOME_MINI_BLOCK。
# 档位 A/B 的迷你行（_home_mini_row）与档位 C 的迷你网格（_home_render_mini_grid）
# 共用这一套（无图标，一行 `▶/▸ 名称  描述`）。
_home_mini_card() {
  local idx="$1" iw="$2" hline="$3"
  local bcol tcol mark mcol nm info line line_w info_w rest mid
  if _home_is_selected "${idx}"; then
    bcol="${UI_ACCENT}"; tcol="${UI_SEL}"; mark="▶"; mcol="${UI_ACCENT}"
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

# 渲染一个迷你卡网格：从模块下标 <start> 起，<ncols> 列 × <nrows> 行，
# 共 ncols*nrows 张；越过 HOME_KEYS 末尾的格子不画（7 个模块除不尽时不拖空卡）。
#
# 宽度几何：先扣掉两侧各 1 列的内边距，再按 ncols 张卡 + (ncols-1) 个 2 列间隙
# 反推卡宽并**向下取整**（cw 固定，同一网格里每张卡一样宽，末行只剩 1 张时也照旧）。
# 每行各自按 UI_COLS 居中：行内卡数与 cw 定下来后，两侧空位由公式给出，末行不满
# （7 张按 2 列铺，第 4 行只有 1 张）时也不会偏到左边。
# 高度：每张 3 行，行与行之间空 1 行（与全文件一致），行距只在还有下一行时输出。
# 档位 C 的正文就是 `_home_render_mini_grid 0 2 4 1`（7 张迷你卡 2 列 × 4 行 = 15 行，
# 末行空出的那格补 1 个装饰卡框）；档位 A/B 的三列栅格不走这里——它们的卡宽是定值 25
# （见 _home_icon_row / _home_mini_row）。
# 第 4 个参数 <decor_last> 是**末行**要补的装饰卡框数（同尺寸、不可选中，见 _home_decor_rows）：
# 其它行不满时不补（本仓库只会用 0 或末行那一个空位）。
_home_render_mini_grid() {
  local start="$1" ncols="$2" nrows="$3" decor_last="${4:-0}"
  (( ncols < 1 )) && ncols=1
  (( nrows < 1 )) && nrows=1
  (( decor_last < 0 )) && decor_last=0
  local GAP=2
  local cw=$(( (UI_COLS - 2 - (ncols - 1) * GAP) / ncols ))
  (( cw < 1 )) && cw=1
  local iw=$((cw - 2))
  (( iw < 1 )) && iw=1
  local gapstr hline i
  printf -v gapstr '%*s' "${GAP}" ''
  hline=""
  for ((i = 0; i < iw; i++)); do hline+="${_UI_BOX_H}"; done

  local total="${#HOME_KEYS[@]}"
  local -a cells blk
  local row idx l line row_w row_pad
  local rowpadstr
  for ((row = 0; row < nrows; row++)); do
    cells=()
    for ((i = 0; i < ncols; i++)); do
      idx=$(( start + row * ncols + i ))
      (( idx < total )) && cells+=("${idx}")
    done
    # 末行空出来的格子补装饰卡框（同尺寸、不可选中）。
    local ndecor=0
    (( row == nrows - 1 )) && ndecor="${decor_last}"
    # 这一行一张卡都没有（前面的格子已用尽）就整行不画，免得拖出一串空行。
    (( ${#cells[@]} == 0 && ndecor == 0 )) && continue
    blk=()
    for idx in "${cells[@]}"; do
      _home_mini_card "${idx}" "${iw}" "${hline}"
      blk+=("${_HOME_MINI_BLOCK[@]}")
    done
    for ((i = 0; i < ndecor; i++)); do
      _home_decor_rows "${cw}" 3 "${hline}"
      blk+=("${_HOME_DECOR_BLOCK[@]}")
    done
    # 每行各自居中：行宽用**本行实际格数**（真卡 + 装饰框）算，末行不满时不会偏到左边。
    local ncells=$(( ${#cells[@]} + ndecor ))
    row_w=$(( ncells * cw + (ncells - 1) * GAP ))
    row_pad=$(( (UI_COLS - row_w) / 2 ))
    (( row_pad < 0 )) && row_pad=0
    printf -v rowpadstr '%*s' "${row_pad}" ''
    for ((l = 0; l < 3; l++)); do
      line=""
      for ((i = 0; i < ncells; i++)); do
        (( i > 0 )) && line+="${gapstr}"
        line+="${blk[$((i * 3 + l))]}"
      done
      printf '%s%s\n' "${rowpadstr}" "${line}"
    done
    # 行距：还有下一行、且下一行真的会画出卡时才空行。
    if (( row < nrows - 1 && start + (row + 1) * ncols < total )); then
      printf '\n'
    fi
  done
}

# 兼容名：docs/palette-lab.sh 的档位分支按**函数名**调渲染器（那个文件不允许改），
# 它在档位 B 下调本函数。新档位下的 B 就是上面那个 3+3+1 正文（前 3 张图标卡 +
# 后 4 张迷你卡），所以这里直接转调 _home_render_cards，预览工具看到的才是真实版式。
# 注意：档位 C 的正文不走这里，render_home 直接调 _home_render_mini_grid（见下）。
_home_render_mini() {
  _home_render_cards
}

# 档位 D：1 列紧凑行。这是 UI_COLS < 40 的兜底档，没有任何宽度/高度下限，
# 因此这里必须自己把两条硬不变量撑住（见 docs/ARCHITECTURE.md）：
#   * 每行 <= UI_COLS —— 极窄时把模块名也截断（此前名字不参与预算，UI_COLS <= 9 必溢出）
#   * 帧高 <= UI_ROWS - chrome —— 极矮时按滑动窗口只渲染选中项所在的一段
_home_render_list() {
  local pad=0
  (( UI_COLS > 24 )) && pad=1
  local padstr
  printf -v padstr '%*s' "${pad}" ''
  local budget=$(( UI_COLS - pad ))
  (( budget < 0 )) && budget=0

  # 行窗口：可见行数不超过正文高度，且选中项必须落在窗口内（窗口口径同设置页）。
  # 高度不足时不强行渲染——正文预算为 0 时多画一行就会把帧顶穿。
  # 正文预算同样走唯一口径 banner_chrome_rows（显式传入优先）。
  local total="${#HOME_KEYS[@]}" body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows home
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      body=$(( UI_ROWS - 5 ))
    fi
  fi
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
  local body="${1:-}"
  _home_layout "${body}"
  _home_palette
  case "${_HOME_TIER}" in
    A|B)
      # 同一个 3+3+1 正文渲染器：档位 A 七张全图标卡，档位 B 前 3 张图标卡、
      # 行 2/行 3 降成迷你卡——差别在它内部按 _HOME_TIER 选卡的种类。
      _home_render_cards
      ;;
    C) _home_render_mini_grid 0 2 4 1 ;;
    *) _home_render_list "${body}" ;;
  esac
}

# 垂直移动（上=-1 / 下=+1），在 _home_row_sizes 给出的行阶梯上走。
# 行内列号按**比例**映射到目标行：nc = inrow * to / from（to < from 时靠左收拢）。
# 例：3+3+1 栅格里第一行按下 —— 第 0 格→第二行第 0 格、第 1 格→第 1 格、第 2 格→第 2 格；
# 第二行第 0 格按下 → 第三行第 0 格（就是卡 6）。
# 目标行在该列**没有卡片**时保持原位（返回 1，不丢弃按键也不跨列吸附）：
# 3+3+1 的第三行只有第 1 列，所以第二行第 1/2 格按下不动；同一套规则也管住了
# 档位 C 的末行（2 列铺 7 张，末行只有 1 张）。
# 不许写成 HOME_SEL ± 列数：各行格数是 3/3/1，列数根本不唯一。
_home_move_vertical() {
  local delta="$1"
  _home_pos
  local nrows="${#_HOME_ROWS[@]}"
  local nr=$(( _HOME_ROW + delta ))
  (( nr < 0 || nr >= nrows )) && return 1
  local from="${_HOME_ROWS[_HOME_ROW]}" to="${_HOME_ROWS[$nr]}"
  (( from < 1 )) && from=1
  (( to < 1 )) && to=1
  # 目标行在该列没有卡片：保持原位（不是夹到最后一格——那会把「第 4 张按下」这种
  # 本来无路可走的按键硬拽到第 7 张卡上）。
  (( _HOME_INROW >= to )) && return 1
  local nc=$(( _HOME_INROW * to / from ))
  (( nc > to - 1 )) && nc=$(( to - 1 ))
  (( nc < 0 )) && nc=0
  local start=0 i
  for (( i = 0; i < nr; i++ )); do
    start=$(( start + _HOME_ROWS[i] ))
  done
  HOME_SEL=$(( start + nc ))
  return 0
}

handle_home_key() {
  local key="$1" row_n
  _home_layout
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
      _home_pos
      if (( _HOME_ROW == 0 )); then
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
      # 左右只在**本行内**移动：3+3+1 栅格里行 1/行 2 各 3 格、行 3 只有 1 格（不动），
      # 到行首/行尾就夹住，绝不跨行乱跳（跨行是上下键的事）。
      [[ "${HOME_FOCUS}" == "grid" ]] || return 0
      _home_pos
      (( _HOME_INROW > 0 )) && (( HOME_SEL -= 1 ))
      ;;
    RIGHT)
      [[ "${HOME_FOCUS}" == "grid" ]] || return 0
      _home_pos
      row_n="${_HOME_ROWS[_HOME_ROW]}"
      (( row_n < 1 )) && row_n=1
      if (( _HOME_INROW < row_n - 1 && HOME_SEL < ${#HOME_KEYS[@]} - 1 )); then
        (( HOME_SEL += 1 ))
      fi
      ;;
  esac
}
