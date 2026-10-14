#!/usr/bin/env bash
# tui.sh —— 主事件循环与导航。source 所有 lib 与 views，进入 tui_main。

set -euo pipefail

_TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载核心库。
for _lib in core settings http session creds parse sjd ucloud public ui icons banner submit; do
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
TUI_TABS=(home assignments schedule classrooms grades exams public settings)

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

# 顶部标题栏。
# 首页且大字符块可显示时：1 行状态行（左=页名，右=账号 + ⚙ 设置）+ 6 行居中块。
# 其余情况（含一切降级路径）：与改动前逐字节相同的 1 行顶栏。
tui_render_header() {
  local title right gear title_w left_w right_w gear_w avail pad i gap
  local banner=0 left_prefix left_prefix_w bpad bpadstr
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
    banner="${BANNER_ACTIVE}"
    if (( banner )); then
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
  # 大字符块：整块居中，左位移 (UI_COLS - 47) / 2 向下取整，每行恒 47 列。
  if (( banner )); then
    bpad=$(( (UI_COLS - BANNER_W) / 2 ))
    (( bpad < 0 )) && bpad=0
    printf -v bpadstr '%*s' "${bpad}" ''
    banner_render "${UI_ACCENT}"
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
  fi
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
  # 在本次改动里也变了**（尾部新增 ` · c 设置`，是任务 B 的有意跨站变更），所以
  # 「不定义钩子的页面输出与改动前逐字节一致」**不成立**——别拿这句话当回归判据。
  local hint=""
  if declare -F "footer_hint_${TUI_VIEW}" >/dev/null 2>&1; then
    hint="$("footer_hint_${TUI_VIEW}")"
  fi
  [[ -n "${hint}" ]] || hint="↑↓ 选择 · Enter 进入 · Esc 返回 · q 退出 · Tab 切换 · c 设置"
  # 窄终端适配：core_fit 按显示列硬切，切在词中间会露出半截字（40 列下
  # 「q 退出」曾被切成「q 退」）。提示串以 ' · ' 分段，放不下时**从尾部整段整段地丢**，
  # 直到剩下的能放下；${hint% · *} 连同分隔符一起摘掉，不会留下悬空的 ' ·'。
  # 兜底：连第一段都超预算时循环自然退出，hint 只剩首段，仍交给 core_fit 硬切
  # （此时半截字不可避免，但本行宽度与改动前一致）。
  # 放得下（宽度 ≤ 预算）时循环一次都不进，hint 逐字节不动 → 相对**本次截断改动之前**
  # 完全相同（相对 HEAD 仍差尾部新增的 ` · c 设置`，见上）。
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
  printf ' %s\n' "$(ui_paint muted "$(core_fit "${hint}" "${budget}")")"
}

# 整屏渲染：标题 + 内容 + 底部。
# 先写入临时帧缓冲（花括号组，全局状态保留），再一次性输出，避免逐行重绘闪烁。
# 用 \033[2J 全清屏（单次写入、原子更新，不会白闪），彻底清除上一帧残留的文字与高亮底色。
tui_render() {
  {
    # 起手先发本主题底色（UI_BG），再擦屏：依赖 BCE（背景色擦除），让 \033[2J 擦出的
    # 空白本身就带着底色——这是「整屏铺底」的关键一步，缺失则清屏处会露出终端原底色。
    # UI_BG 为空（尚未应用主题）时 printf 什么都不输出，与改动前逐字节一致。
    printf '%s' "${UI_BG}"
    printf '\033[2J\033[H'
    tui_render_header
    local i
    for ((i = 0; i < UI_COLS; i++)); do printf '%s' "${_UI_BOX_H}"; done
    printf '\n'
    # 正文可用行数 = UI_ROWS - chrome 行数，唯一的 chrome 口径由 banner_chrome_rows 给出
    # （首页出块 11、其余 5）。每次渲染都按当前尺寸重算，不缓存。
    local body
    banner_chrome_rows
    body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    (( body < 0 )) && body=0
    render_${TUI_VIEW} "${body}" || true
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
  trap '_async_stop; rm -f "${TUI_FRAME_FILE}"; ui_exit_alt_screen; ui_restore_mode' EXIT
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
    ui_size
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
