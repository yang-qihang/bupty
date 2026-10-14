#!/usr/bin/env bash
# tui.sh —— 主事件循环与导航。source 所有 lib 与 views，进入 tui_main。

set -euo pipefail

_TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载核心库。
# 合并注意：本行两边都加了新库——本分支加 ui/icons/banner，main 加 booking，这里取并集。
for _lib in core settings http session creds parse sjd ucloud public ui icons banner submit booking; do
  # shellcheck disable=SC1090
  source "${_TUI_DIR}/lib/${_lib}.sh"
done
# 加载视图。
for _view in "${_TUI_DIR}"/lib/views/*.sh; do
  # shellcheck disable=SC1090
  source "${_view}"
done

# ---------------------------------------------------------------------------
# 导航状态
# ---------------------------------------------------------------------------

TUI_VIEW="home"
TUI_QUIT=0
TUI_STATUS=""
TUI_NAV_STACK=()

tui_switch() {
  TUI_VIEW="$1"
}

# 进入子视图（保存当前视图，Esc 返回）。
tui_push() {
  TUI_NAV_STACK+=("${TUI_VIEW}")
  TUI_VIEW="$1"
}

# 返回上一层；栈空则回首页。
tui_back() {
  if [[ ${#TUI_NAV_STACK[@]} -gt 0 ]]; then
    TUI_VIEW="${TUI_NAV_STACK[-1]}"
    unset 'TUI_NAV_STACK[-1]'
  else
    TUI_VIEW="home"
  fi
}

tui_quit() {
  TUI_QUIT=1
}

tui_set_status() {
  TUI_STATUS="$1"
  BUPTY_ERR=""
}

# 顶级标签页顺序（用于 Tab 切换）。
TUI_TABS=(home assignments schedule classrooms grades exams public booking settings)

# 顶栏页签条的短标签。**与 TUI_TABS 必须等长、按位对应**（改一个数组就必须同步改另一个；
# 错位会让页签条把 A 的名字挂在 B 的页上，而且不会有任何报错）。
# 刻意不复用 ui_view_title：那是页面自己的长标题（作业 DDL / 空教室 / 公共查询），
# 9 个签要挤进一行且每个签自带高亮块，只有最短可辨名放得下。
TUI_TAB_LABELS=(首页 作业 课表 教室 成绩 考试 公共 研讨间 设置)

# 取视图的页签短名，结果写全局 TUI_TAB_LABEL（**不写 stdout**）。
# 与 _core_width / banner_chrome_rows 同一约定：每帧都要遍历 9 个签，MSYS2 上一次
# $( ) 就是 50ms 的 fork，热路径里不许有（banner.sh 的注释里也记着这条）。
# 找不到（视图不在 TUI_TABS 里）时退回视图名本身，绝不是空串。
tui_tab_label() {
  local view="${1:-}" i
  TUI_TAB_LABEL="${view}"
  for i in "${!TUI_TABS[@]}"; do
    if [[ "${TUI_TABS[$i]}" == "${view}" ]]; then
      TUI_TAB_LABEL="${TUI_TAB_LABELS[$i]}"
      break
    fi
  done
  return 0
}

tui_next_tab() {
  local i cur=-1
  for i in "${!TUI_TABS[@]}"; do
    if [[ "${TUI_TABS[$i]}" == "${TUI_VIEW}" ]]; then cur=$i; break; fi
  done
  if [[ "${cur}" -ge 0 ]]; then
    local next=$(( (cur + 1) % ${#TUI_TABS[@]} ))
    TUI_NAV_STACK=()
    TUI_VIEW="${TUI_TABS[$next]}"
  fi
}

# ---------------------------------------------------------------------------
# 后台拉取（异步加载：切页即时显示，数据后台拉取完成后重绘）
# ---------------------------------------------------------------------------

TUI_FETCH_PID=""
TUI_FETCH_VIEW=""
TUI_FETCH_FILE=""

# 启动后台拉取：_async_start <view> <fetch-func> [args...]
# fetch-func 成功时输出数据到 stdout；失败时输出 "ERROR:消息"。
_async_start() {
  local view="$1" func="$2"
  shift 2
  _async_stop
  TUI_FETCH_VIEW="$view"
  TUI_FETCH_FILE="$(mktemp)"
  (
    if "${func}" "$@"; then
      exit 0
    else
      printf 'ERROR:%s' "${BUPTY_ERR:-加载失败}"
    fi
  ) > "${TUI_FETCH_FILE}" 2>/dev/null &
  TUI_FETCH_PID=$!
}

# 终止当前后台拉取并清理。
_async_stop() {
  if [[ -n "${TUI_FETCH_PID}" ]]; then
    kill "${TUI_FETCH_PID}" 2>/dev/null || true
    wait "${TUI_FETCH_PID}" 2>/dev/null || true
  fi
  [[ -n "${TUI_FETCH_FILE}" ]] && rm -f "${TUI_FETCH_FILE}"
  TUI_FETCH_PID=""
  TUI_FETCH_VIEW=""
  TUI_FETCH_FILE=""
}

# 轮询后台拉取：完成则调用视图 apply 回调并返回 0（需重绘），否则返回 1。
_async_poll() {
  [[ -z "${TUI_FETCH_PID}" ]] && return 1
  if kill -0 "${TUI_FETCH_PID}" 2>/dev/null; then
    return 1
  fi
  local view="${TUI_FETCH_VIEW}" file="${TUI_FETCH_FILE}"
  TUI_FETCH_PID=""
  TUI_FETCH_VIEW=""
  TUI_FETCH_FILE=""
  if declare -F "apply_${view}" >/dev/null 2>&1; then
    "apply_${view}" "${file}"
  fi
  rm -f "${file}"
  return 0
}

# ---------------------------------------------------------------------------
# 渲染框架
# ---------------------------------------------------------------------------

# 顶部标题栏拆成两段，中间给页签条让位（用户 2026-10-14 定的版式）：
#   tui_render_statusline  1 行状态行（左=页名，右=账号 + ⚙ 设置）
#   tui_render_tabbar      页签条 1 行 + 其下线 1 行（由 tui_render 补线）
#   tui_render_bannerblock 首页大字符块 6 行（首页且块可显示时）
# 三段拼起来与拆分前逐字节相同，只有**顺序**变了（页签条从块下方提到状态行正下方），
# 所以 lib/banner.sh 的 chrome 口径一个数都不用动（首页 11、其余 5，加页签条 +2）。
tui_render_statusline() {
  local title right gear title_w left_w right_w gear_w avail pad i gap
  local left_prefix left_prefix_w
  title="$(ui_view_title "${TUI_VIEW}")"
  if creds_exists 2>/dev/null; then
    right="${BUPTY_ACCOUNT} · 已登录"
  else
    right="未登录"
  fi
  # 设置从模块级降到顶栏右侧：账号状态之后跟一个 ⚙ 设置 焦点项。
  # 顶栏**只写名字、不写键位**：直达键（`c`）只在页脚提示里出现，一处说明就够，
  # 顶栏再挂一个字符会和「⚙ 设置 c」这种半中半英的读法一样碍眼（用户 2026-10-14 定的）。
  gear="⚙ 设置"
  # 「 bupty」本身固定占 6 列，再加一个分隔空格。
  left_prefix=" ${BUPTY_NAME}"
  left_prefix_w=6
  # 首页大字符块：块启用时状态行左侧不再重复写 bupty（块里已写 BUPTY），
  # 让出的 6 列正好留给居中的块。
  if [[ "${TUI_VIEW}" == "home" ]]; then
    banner_init
    if (( BANNER_ACTIVE )); then
      left_prefix=""
      left_prefix_w=0
    fi
  fi
  # 标题与它右侧的内容之间**希望**留 ≥1 格。
  # 注意：这只是意图，没有下限保证。pad 在「一切都放得下」的分支里算出来可以是 0
  # （实测 UI_COLS=25 未登录态：avail = 25-11-6-2 = 6，pad = 6-6 = 0，渲染成
  # 「 bupty 首页未登录  ⚙ 设置」，首页与未登录贴死）。**这是 HEAD 上就有的既有行为**，
  # 本分支未引入也未扩大（HEAD 的同一函数条件逐字相同）；要收口需单独一个改动。
  gap=1
  title_w="$(core_fit_width "${title}")"
  left_w=$(( left_prefix_w + 1 + title_w ))
  right_w="$(core_fit_width "${right}")"
  gear_w="$(core_fit_width "${gear}")"
  # 连前缀都放不下（现实终端不会出现）：只保留能放下的部分，保证不溢出。
  if (( UI_COLS < left_prefix_w + 1 )); then
    if [[ -n "${left_prefix}" ]]; then
      printf '%s\n' "$(ui_paint accent "$(core_fit "${left_prefix}" "${UI_COLS}")")"
    else
      printf '\n'
    fi
    return 0
  fi
  if (( left_w + right_w + gear_w + 2 > UI_COLS )); then
    # 空间不足：从右往左逐级让位——先丢掉账号状态，再把「⚙ 设置」退成「⚙」，
    # 再退到整个丢掉齿轮，最后才把标题截断到剩余空间。这样极窄终端下
    # 还留得住标题，而不是把齿轮硬挤在标题后面。
    right=""
    if (( left_w + gap + gear_w > UI_COLS )); then
      gear="⚙"
      gear_w="$(core_fit_width "${gear}")"
    fi
    if (( left_w + gap + gear_w > UI_COLS )); then
      gear=""
      gear_w=0
    fi
    # 标题最多占满让位后剩下的空间（齿轮还在时要先扣掉 gap 与齿轮本身）。
    avail=$(( UI_COLS - left_prefix_w - 1 ))
    (( gear_w > 0 )) && avail=$(( avail - gap - gear_w ))
    (( avail < 0 )) && avail=0
    if (( title_w > avail )); then
      title="$(core_fit "${title}" "${avail}")"
      title_w="${avail}"
    fi
    left_w=$(( left_prefix_w + 1 + title_w ))
    pad=$(( UI_COLS - left_w - gear_w ))
    (( pad < 0 )) && pad=0
  else
    avail=$(( UI_COLS - left_w - gear_w - 2 ))
    if (( right_w > avail )); then
      right="$(core_fit "${right}" "${avail}")"
      pad=0
    else
      pad=$(( avail - right_w ))
    fi
  fi
  if [[ -n "${left_prefix}" ]]; then
    printf '%s' "$(ui_paint accent "${left_prefix}")"
  fi
  printf ' %s' "$(ui_paint title "${title}")"
  for ((i = 0; i < pad; i++)); do printf ' '; done
  if [[ -n "${right}" ]]; then
    printf '%s' "$(ui_paint muted "${right}")"
    printf '  '
  fi
  if [[ "${TUI_VIEW}" == "home" && "${HOME_FOCUS:-grid}" == "settings" ]]; then
    printf '%s' "$(ui_paint hl "${gear}")"
  else
    printf '%s' "$(ui_paint accent "${gear}")"
  fi
  printf '\n'
  return 0
}

# 首页大字符块：整块居中，左位移 (UI_COLS - 47) / 2 向下取整，每行恒 47 列。
# 不自判是否该出——判据只有一个（BANNER_CHROME_ROWS 是否含这 6 行，由 banner_chrome_rows
# 算出），tui_render 只在该出时才调本函数，这里再判一次就会和 chrome 口径分叉。
tui_render_bannerblock() {
  local i bpad bpadstr
  banner_render "${UI_ACCENT}"
  bpad=$(( (UI_COLS - BANNER_W) / 2 ))
  (( bpad < 0 )) && bpad=0
  printf -v bpadstr '%*s' "${bpad}" ''
  for ((i = 0; i < BANNER_H; i++)); do
    # banner 行自带裸 \033[0m（lib/banner.sh 的 _BANNER_RESET），会把底色打回终端默认。
    # 有主题（UI_BG 非空）时把行尾裸 reset 换成 UI_RESET（重置 + 立刻恢复底色），保证帧内
    # 每个 \033[0m 之后都紧跟 \033[48;5;N m（底色连续不变量），块内空白始终落在主题底色上；
    # UI_BG 为空时原样输出，与改动前逐字节一致。
    if [[ -n "${UI_BG}" ]]; then
      printf '%s%s\n' "${bpadstr}" "${BANNER_ROWS[$i]%$'\033[0m'}${UI_RESET}"
    else
      printf '%s%s\n' "${bpadstr}" "${BANNER_ROWS[$i]}"
    fi
  done
  return 0
}

# 顶栏页签条（1 行，居中）：签之间 2 个空格，当前页反白（UI_HL 底 + UI_HL_FG 字），
# 其余签 UI_MUTED；整行以 UI_RESET 收（每个 UI_RESET 之后都紧跟主题底色，底色连续）。
# 形状（上线由 tui_render 那条分隔线充当，本函数只画中间这一行，下线也由 tui_render 补）：
#   ──────────────
#    首页  作业  课表  教室  成绩  考试  公共  研讨间  设置
#   ──────────────
# **本函数不判显示条件**：显示/隐藏的唯一判据在 lib/banner.sh 的 banner_chrome_rows
# （它把结果写进 BANNER_TABBAR_ROWS），tui_render 只在 BANNER_TABBAR_ROWS > 0 时调用。
tui_render_tabbar() {
  local plain="" colored="" label="" i n pad sp
  n=${#TUI_TABS[@]}
  for ((i = 0; i < n; i++)); do
    tui_tab_label "${TUI_TABS[$i]}"
    label="${TUI_TAB_LABEL}"
    if (( i > 0 )); then
      # 签间 2 个空格。放在前一个签的 UI_RESET 之后：底色已恢复，空白落在主题底色上。
      plain+="  "
      colored+="  "
    fi
    plain+="${label}"
    if [[ "${TUI_TABS[$i]}" == "${TUI_VIEW}" ]]; then
      # 当前页：反白块（UI_HL 给背景、UI_HL_FG 给前景）。两个角色都**含背景色**，
      # 这里就是「整行铺满」之外允许出背景的第二个地方——块宽恰好等于名字宽。
      colored+="${UI_HL}${UI_HL_FG}${label}${UI_RESET}"
    else
      colored+="${UI_MUTED}${label}${UI_RESET}"
    fi
  done
  # 居中：宽度一律用 _core_width 量**无色**的 plain（绝不用 ${#s}——签里全是 CJK，
  # 字节数 ≠ 显示列；更不能用带 ANSI 的 colored，转义会被当成可见列算进去）。
  _core_width "${plain}"
  pad=$(( (UI_COLS - _CORE_W) / 2 ))
  (( pad < 0 )) && pad=0
  printf -v sp '%*s' "${pad}" ''
  printf '%s%s\n' "${sp}" "${colored}"
}

# 视图标题（供顶栏与帮助）。
ui_view_title() {
  case "$1" in
    home) printf '首页' ;;
    settings) printf '设置' ;;
    assignments) printf '作业 DDL' ;;
    schedule) printf '课表' ;;
    classrooms) printf '空教室' ;;
    grades) printf '成绩' ;;
    exams) printf '考试' ;;
    public) printf '公共查询' ;;
    booking) printf '研讨间' ;;
    *) printf '%s' "$1" ;;
  esac
}

# 底部状态栏 + 快捷键提示。
tui_render_footer() {
  local i
  local sep="${UI_BORDER}${_UI_BOX_H}${UI_RESET}"
  local line=""
  for ((i = 0; i < UI_COLS; i++)); do line+="${_UI_BOX_H}"; done
  printf '%s%s%s\n' "${UI_BORDER}" "${line}" "${UI_RESET}"
  # 状态行
  local status="${TUI_STATUS}"
  if [[ -n "${BUPTY_ERR}" ]]; then
    status="${BUPTY_ERR}"
  fi
  printf ' %s\n' "$(ui_paint muted "$(core_fit "${status:-就绪}" "$((UI_COLS - 2))")")"
  # 快捷键提示：默认串 + 页面可选覆盖点。
  # 覆盖点 footer_hint_<view> 输出非空则替换默认提示串；未定义或输出为空 = 用默认串。
  # 这样「选择器打开时 Enter 是保存、Esc 是撤销」这类页面级键位语义变化，页脚能说实话。
  # 注意（原注释写错过，已更正）：钩子本身不给默认路径增加任何一个字节，但**默认串自己
  # 在本次改动里也变了**（尾部新增 ` · r 刷新 · c 设置`：前者来自 main，后者是本分支的
  # 有意跨站变更），所以「不定义钩子的页面输出与改动前逐字节一致」**不成立**——别拿这句当回归判据。
  local hint=""
  if declare -F "footer_hint_${TUI_VIEW}" >/dev/null 2>&1; then
    hint="$("footer_hint_${TUI_VIEW}")"
  fi
  [[ -n "${hint}" ]] || hint="↑↓ 选择 · Enter 进入 · Esc 返回 · q 退出 · Tab 切换 · r 刷新 · c 设置"
  # 窄终端适配：core_fit 按显示列硬切，切在词中间会露出半截字（40 列下
  # 「q 退出」曾被切成「q 退」）。提示串以 ' · ' 分段，放不下时**从尾部整段整段地丢**，
  # 直到剩下的能放下；${hint% · *} 连同分隔符一起摘掉，不会留下悬空的 ' ·'。
  # 兜底：连第一段都超预算时循环自然退出，hint 只剩首段，仍交给 core_fit 硬切
  # （此时半截字不可避免，但本行宽度与改动前一致）。
  # 放得下（宽度 ≤ 预算）时循环一次都不进，hint 逐字节不动 → 相对**本次截断改动之前**
  # 完全相同（相对 HEAD 仍差尾部新增的两段，见上）。
  local budget=$((UI_COLS - 2))
  _core_width "${hint}"
  if (( _CORE_W > budget )); then
    while [[ "${hint}" == *" · "* ]]; do
      hint="${hint% · *}"
      _core_width "${hint}"
      # 显式 if（而非 `(( )) && break`）：本函数在 set -e 下运行，写成 if 条件
      # 不会因「条件为假」被当成失败命令。
      if (( _CORE_W <= budget )); then break; fi
    done
  fi
  # 末行不带换行（main 的改动，本分支保留）：满屏内容时避免末尾 \n 使终端上滚一行、
  # 把页眉顶出屏幕。
  printf ' %s' "$(ui_paint muted "$(core_fit "${hint}" "${budget}")")"
}

# 整屏渲染，自上而下：状态行 →（页签条 + 分隔线）→（大字符块 + 分隔线）→ 正文 → 页脚。
# 页签条紧贴状态行（固定位置，首页有块时也不会被块挤到中间去），大块退到页签条之下。
# 先写入临时帧缓冲（花括号组，全局状态保留），再一次性输出，避免逐行重绘闪烁。
# 用 \033[2J 全清屏（单次写入、原子更新，不会白闪），彻底清除上一帧残留的文字与高亮底色。
tui_render() {
  {
    # 起手先发本主题底色（UI_BG），再擦屏：依赖 BCE（背景色擦除），让 \033[2J 擦出的
    # 空白本身就带着底色——这是「整屏铺底」的关键一步，缺失则清屏处会露出终端原底色。
    # UI_BG 为空（尚未应用主题）时 printf 什么都不输出，与改动前逐字节一致。
    printf '%s' "${UI_BG}"
    printf '\033[2J\033[H'
    # 状态行永远第 1 行；页签条紧贴它下方（固定位置），大块再往下。
    tui_render_statusline
    # banner_chrome_rows 每次渲染按当前尺寸重算（不缓存），产出两个值：BANNER_CHROME_ROWS
    # 与 BANNER_TABBAR_ROWS（页签条显示时 2 / 否则 0，是「画不画页签条」的唯一判据）。
    # 注意：BANNER_CHROME_ROWS 是**视图侧默认推导用的保守口径**，帧里真正画出的行数由下面
    # `chrome` 现数——两者差 1（页签条那 3 行被记作 2 行），别拿它当正文预算。
    # **必须先问它再判大块**：BANNER_ACTIVE 只在视图是 home 时才被 banner_chrome_rows 刷新，
    # 它是首页专属状态。换个视图后 BANNER_ACTIVE 仍留着上一帧的值，若直接读它，切到课表
    # 也会照画 6 行 BUPTY —— 帧高不变量照样通过（块塌成空的），但画面全错。
    # 所以判据取自 chrome：base = chrome - 页签条；base > 5 当且仅当首页且块可显示。
    local base
    banner_chrome_rows
    base=$(( BANNER_CHROME_ROWS - BANNER_TABBAR_ROWS ))
    local i
    # 页签条（上线由本函数补，下线紧随其后）。显示与否只看 BANNER_TABBAR_ROWS —— 不另判条件。
    if (( BANNER_TABBAR_ROWS > 0 )); then
      for ((i = 0; i < UI_COLS; i++)); do printf '%s' "${_UI_BOX_H}"; done
      printf '\n'
      tui_render_tabbar
      for ((i = 0; i < UI_COLS; i++)); do printf '%s' "${_UI_BOX_H}"; done
      printf '\n'
    fi
    if (( base > 5 )); then
      tui_render_bannerblock
    fi
    # 正文上方那条分隔线：页签条已画了下线、中间又没有大块时**不补**——否则就是两条
    # 一模一样的整宽横线贴在一起（不出块的各页肉眼可见，改前就是这个样子）。
    if (( base > 5 )) || (( BANNER_TABBAR_ROWS == 0 )); then
      for ((i = 0; i < UI_COLS; i++)); do printf '%s' "${_UI_BOX_H}"; done
      printf '\n'
    fi
    # 帧高不变量（2026-10-14 的真正修法）：正文行数要让**上面实际画出的行数恰好等于 UI_ROWS**。
    # 写进终端时只有 `\n` 让光标下移，而页脚末行不带换行（见 tui_render_footer 末尾的
    # `printf ' %s'`），所以「画出 UI_ROWS 行」＝「帧里 UI_ROWS-1 个换行」＝光标停在第 UI_ROWS 行、
    # 不触发滚屏。少一行就把第 1 行状态条顶出屏幕；多一行则末行与页脚分隔线粘在一起。
    #
    # chrome 在这里**如实数一遍**，不再用 BANNER_CHROME_ROWS：那个口径把页签条记成 2 行
    # （签 1 + 下线 1），可上面为它实际画了 3 行（上线 + 签 + 下线），差额 1 正是空教室列表
    # 填满正文时状态条被顶出去的成因。BANNER_CHROME_ROWS 继续留给视图侧的默认推导
    # （`body = UI_ROWS - BANNER_CHROME_ROWS`）与页签条高度门槛——那两处只要保守即可，
    # 不要求精确；tui_render 一律传 body 进去，视图不自己减常量。
    local chrome=1                                              # 状态行
    if (( BANNER_TABBAR_ROWS > 0 )); then chrome=$(( chrome + 3 )); fi   # 上线 + 签 + 下线
    if (( base > 5 )); then
      chrome=$(( chrome + BANNER_H ))                           # 大字符块
      chrome=$(( chrome + 1 ))                                  # 块下那条分隔线
    elif (( BANNER_TABBAR_ROWS == 0 )); then
      chrome=$(( chrome + 1 ))                                  # 页签条没画时唯一的那条线
    fi
    chrome=$(( chrome + 3 ))                                    # 页脚：分隔线 + 状态 + 键位
    local body=$(( UI_ROWS - chrome ))
    (( body < 0 )) && body=0
    render_"${TUI_VIEW}" "${body}"
    tui_render_footer
    printf '\033[J'
  } > "${TUI_FRAME_FILE}"
  printf '%s' "$(< "${TUI_FRAME_FILE}")"
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------

tui_main() {
  ui_theme_init
  ui_size
  creds_load || true
  ui_raw_mode
  ui_hide_cursor
  ui_enter_alt_screen
  # 图标层内部完成 DSR 宽度实测(复用 lib/core.sh 的 core_probe_ambig)，
  # 实测成功时回写 BUPTY_AMBIG_W / ICON_UNICODE_W。必须在备用屏幕之后、第一帧之前。
  icon_init
  # 边框字符必须在 icon_init 之后确定:读 ICON_UNICODE_W 决定制表符是否退 ASCII。
  ui_box_init
  TUI_FRAME_FILE="$(mktemp)"
  trap '_async_stop; rm -f "${TUI_FRAME_FILE}"; rm -f "${BUPTY_BOOKING_COOKIE_JAR:-}" 2>/dev/null || true; ui_exit_alt_screen; ui_restore_mode' EXIT
  # 窗口尺寸变化时置位，主循环在下个超时点立即重绘（响应 resize）。
  trap 'TUI_RESIZED=1' WINCH

  local key
  ui_size
  tui_render
  while [[ "${TUI_QUIT}" -eq 0 ]]; do
    key="$(ui_read_key 0.3)"
    if [[ "${key}" == "TIMEOUT" ]]; then
      # 空闲超时：后台拉取完成则重绘；窗口尺寸变化也重绘。
      if _async_poll; then
        ui_size
        tui_render
      elif [[ -n "${TUI_RESIZED:-}" ]]; then
        TUI_RESIZED=""
        ui_size
        tui_render
      fi
      continue
    fi
    case "${key}" in
      IGNORE) continue ;;   # 鼠标等被忽略的输入，不重绘。
      q|EOF) tui_quit ;;
      TAB) tui_next_tab ;;
      # 设置直达键：`c`（config / 配置）。
      # 历史：先用过 `,`。逗号是标点，在中文界面里「⚙ 设置 ,」不好看，也容易在
      # 中英混排里被误读，2026-10-14 按用户要求改成字母。
      # 为什么不是 `s`（用户首选）：`s` 已被 lib/views/assignments.sh:380 的
      # `s|ENTER)`（提交作业）占用，而 tui_main 的 case 在视图 handler 之前，
      # 全局键会把作业页的 `s` 吃掉——不能抢。
      # 其余被占的单字母：f（空教室）r（各页刷新）t p 1 0（成绩页）。`c` 全空闲。
      # ui_read_key 对普通字母原样返回 token（lib/ui.sh:595 的 `*)` 分支），无变形。
      c) tui_switch settings ;;
      ESC|BACKSPACE)
        # 页面可选的接管点：handle_<view>_escape 返回 0 = 这次 Esc 已被页面消费（不返回上一页）。
        # 未定义或返回非 0 = 维持原行为。现有 8 个页面都没定义它，行为与改动前逐字节一致。
        if declare -F "handle_${TUI_VIEW}_escape" >/dev/null 2>&1 \
           && "handle_${TUI_VIEW}_escape"; then
          :
        else
          tui_back
        fi
        ;;
      *)
        if declare -F "handle_${TUI_VIEW}_key" >/dev/null 2>&1; then
          # 视图 handler 失败（如刷新失败）不应在 set -e 下终止整个 TUI。
          "handle_${TUI_VIEW}_key" "${key}" || true
        fi
        ;;
    esac
    tui_render
  done
}

# 单帧渲染入口（供测试捕获）。
tui_render_once() {
  ui_theme_init
  ui_size
  creds_load || true
  # 非 TTY 下 icon_init 判定 off 且不设 ICON_UNICODE_W，ui_box_init 保持 Unicode 边框。
  icon_init
  ui_box_init
  TUI_FRAME_FILE="$(mktemp)"
  tui_render
  rm -f "${TUI_FRAME_FILE}"
}
