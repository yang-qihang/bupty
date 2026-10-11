#!/usr/bin/env bash
# tui.sh —— 主事件循环与导航。source 所有 lib 与 views，进入 tui_main。

set -euo pipefail

_TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载核心库。
for _lib in core http session creds parse sjd ucloud public ui; do
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
tui_render_header() {
  local title right right_w left_w pad i
  title="$(ui_view_title "${TUI_VIEW}")"
  if creds_exists 2>/dev/null; then
    right="${BUPTY_ACCOUNT} · 已登录"
  else
    right="未登录"
  fi
  # 左侧 = " bupty"(6 列) + " "(1 列) + 标题；右侧 = 账号状态。
  left_w=$(( 6 + 1 + $(core_fit_width "${title}") ))
  right_w="$(core_fit_width "${right}")"
  pad=$(( UI_COLS - left_w - right_w ))
  (( pad < 0 )) && pad=0
  printf '%s' "$(ui_paint accent " ${BUPTY_NAME}")"
  printf ' %s' "$(ui_paint title "${title}")"
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
# 先写入临时帧缓冲（花括号组，全局状态保留），再一次性输出，避免逐行重绘闪烁。
# 用 \033[2J 全清屏（单次写入、原子更新，不会白闪），彻底清除上一帧残留的文字与高亮底色。
tui_render() {
  {
    printf '\033[2J\033[H'
    tui_render_header
    local i
    for ((i = 0; i < UI_COLS; i++)); do printf '%s' "${_UI_BOX_H}"; done
    printf '\n'
    render_${TUI_VIEW} || true
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
  ui_box_init
  ui_size
  creds_load || true
  ui_raw_mode
  ui_hide_cursor
  ui_enter_alt_screen
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
      ESC|BACKSPACE) tui_back ;;
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
  ui_box_init
  ui_size
  creds_load || true
  TUI_FRAME_FILE="$(mktemp)"
  tui_render
  rm -f "${TUI_FRAME_FILE}"
}
