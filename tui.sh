#!/usr/bin/env bash
# tui.sh —— 主事件循环与导航。source 所有 lib 与 views，进入 tui_main。

set -euo pipefail

_TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载核心库。
for _lib in core http session creds parse sjd ucloud ui; do
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
# 渲染框架
# ---------------------------------------------------------------------------

# 顶部标题栏。
tui_render_header() {
  local left=" ${BUPTY_NAME}"
  local right=""
  if creds_exists 2>/dev/null; then
    right="${BUPTY_ACCOUNT} · 已登录"
  else
    right="未登录"
  fi
  local width="${UI_COLS}"
  local right_w
  right_w="$(core_fit_width "${right}")"
  printf '%s' "$(ui_paint accent " ${BUPTY_NAME}")"
  printf ' %s' "$(ui_paint title "$(ui_view_title "${TUI_VIEW}")")"
  # 右侧账号状态
  local pad
  pad=$(( width - 2 - 4 - $(core_fit_width "$(ui_view_title "${TUI_VIEW}")") - right_w ))
  (( pad < 0 )) && pad=0
  local i
  for ((i = 0; i < pad; i++)); do printf ' '; done
  printf '%s\n' "$(ui_paint muted "${right}")"
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
  # 快捷键
  printf ' %s\n' "$(ui_paint muted "$(core_fit "↑↓ 选择 · Enter 进入 · Esc 返回 · q 退出 · Tab 切换" "$((UI_COLS - 2))")")"
}

# 整屏渲染：标题 + 内容 + 底部。
tui_render() {
  ui_clear
  tui_render_header
  local i
  for ((i = 0; i < UI_COLS; i++)); do printf '%s' "${_UI_BOX_H}"; done
  printf '\n'
  render_${TUI_VIEW} || true
  tui_render_footer
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------

tui_main() {
  ui_theme_init
  ui_box_init
  ui_size
  creds_load || true
  ui_raw_mode
  ui_hide_cursor
  trap 'ui_restore_mode; ui_clear' EXIT

  local key
  while [[ "${TUI_QUIT}" -eq 0 ]]; do
    ui_size
    tui_render
    key="$(ui_read_key)"
    case "${key}" in
      q) tui_quit ;;
      TAB) tui_next_tab ;;
      ESC|BACKSPACE) tui_back ;;
      *)
        if declare -F "handle_${TUI_VIEW}_key" >/dev/null 2>&1; then
          # 视图 handler 失败（如刷新失败）不应在 set -e 下终止整个 TUI。
          "handle_${TUI_VIEW}_key" "${key}" || true
        fi
        ;;
    esac
  done
}

# 单帧渲染入口（供测试捕获）。
tui_render_once() {
  ui_theme_init
  ui_box_init
  ui_size
  creds_load || true
  tui_render
}
