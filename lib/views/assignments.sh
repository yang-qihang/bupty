#!/usr/bin/env bash
# views/assignments.sh —— 作业 DDL 视图：教学云作业列表与紧急程度着色、滚动选择。

set -euo pipefail

# 视图状态。
ASSIGNMENTS_DATA=""      # 作业 JSON 数组（已成功加载的数据）。
ASSIGNMENTS_ACCOUNT=""   # 数据所属账号。
ASSIGNMENTS_LOADED=0     # 是否已为当前账号加载过（含失败）。
ASSIGNMENTS_SEL=0        # 当前选中行。
ASSIGNMENTS_OFFSET=0     # 列表滚动偏移。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_assignments_stale() {
  [[ "${ASSIGNMENTS_LOADED}" != "1" || "${ASSIGNMENTS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 作业条数。
_assignments_count() {
  local n
  n="$(printf '%s' "${ASSIGNMENTS_DATA:-}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${n}" || "${n}" == "null" ]]; then
    printf '0'
  else
    printf '%s' "${n}"
  fi
}

# 拉取并缓存（不渲染）。成功 0，失败置 BUPTY_ERR 且保留旧数据。
assignments_fetch() {
  # 账号切换时先清空旧账号数据，避免跨账号残留泄漏。
  if [[ "${ASSIGNMENTS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
    ASSIGNMENTS_DATA=""
    ASSIGNMENTS_SEL=0
    ASSIGNMENTS_OFFSET=0
  fi
  # 用临时文件承接 stdout，避免 $(...) 子 shell 丢失 BUPTY_ERR / 会话副作用。
  local tmp data
  tmp="$(mktemp)"
  if ucloud_fetch_assignments > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    ASSIGNMENTS_DATA="${data}"
    ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
    ASSIGNMENTS_LOADED=1
    ASSIGNMENTS_SEL=0
    ASSIGNMENTS_OFFSET=0
    return 0
  fi
  rm -f "${tmp}"
  ASSIGNMENTS_LOADED=1
  ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
  return 1
}

# 刷新（r 键）：先渲染「加载中」，再拉取，再重渲染。
assignments_refresh() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  tui_set_status "正在加载作业…"
  tui_render
  if ! assignments_fetch; then
    return 1
  fi
  local n
  n="$(_assignments_count)"
  tui_set_status "已加载 ${n} 项作业。"
  tui_render
  return 0
}

# 渲染单行：截止日期 + 剩余天数 + 课程名 + 作业标题 + 状态。
_assignments_render_row() {
  local i="$1"
  local row deadline course title status
  row="$(printf '%s' "${ASSIGNMENTS_DATA}" | jq -c '.['"${i}"']' 2>/dev/null || true)"
  [[ -z "${row}" || "${row}" == "null" ]] && return 0
  deadline="$(printf '%s' "${row}" | jq -r '.deadline // ""' 2>/dev/null || true)"
  course="$(printf '%s' "${row}" | jq -r '.course_name // ""' 2>/dev/null || true)"
  title="$(printf '%s' "${row}" | jq -r '.title // ""' 2>/dev/null || true)"
  status="$(printf '%s' "${row}" | jq -r '.status // ""' 2>/dev/null || true)"

  local deadline_disp="${deadline:0:16}"
  local days_disp="" urgency="text"
  if [[ -z "${deadline}" ]]; then
    days_disp="—"
  else
    local d
    d="$(core_days_between "${deadline:0:10}" "$(core_today)")"
    if (( d < 0 )); then
      days_disp="已截止 $((-d)) 天"; urgency="danger"
    elif (( d == 0 )); then
      days_disp="今天截止"; urgency="danger"
    elif (( d <= 3 )); then
      days_disp="剩 ${d} 天"; urgency="warning"
    else
      days_disp="剩 ${d} 天"
    fi
  fi

  local status_color="text"
  case "${status}" in
    未提交) status_color="danger" ;;
    已提交) status_color="success" ;;
    已驳回) status_color="warning" ;;
    已批改) status_color="muted" ;;
  esac

  local title_w=$((UI_COLS - 58))
  if (( title_w < 8 )); then title_w=8; fi

  local raw
  raw="$(printf '%s %s %s %s %s' \
    "$(core_fit "${deadline_disp}" 16)" \
    "$(core_fit "${days_disp}" 11)" \
    "$(core_fit "${course}" 16)" \
    "$(core_fit "${title}" "${title_w}")" \
    "${status}")"

  if [[ "${i}" -eq "${ASSIGNMENTS_SEL}" ]]; then
    printf ' %s%s%s\n' "${UI_HL}" "$(core_fit "${raw}" "$((UI_COLS - 4))")" "${UI_RESET}"
  else
    printf '  %s %s %s %s %s\n' \
      "$(ui_paint "${urgency}" "$(core_fit "${deadline_disp}" 16)")" \
      "$(ui_paint "${urgency}" "$(core_fit "${days_disp}" 11)")" \
      "$(ui_paint text "$(core_fit "${course}" 16)")" \
      "$(ui_paint text "$(core_fit "${title}" "${title_w}")")" \
      "$(ui_paint "${status_color}" "${status}")"
  fi
}

# 渲染列表主体（含顶部账号/总数信息行）。
_assignments_render_list() {
  local total
  total="$(_assignments_count)"
  printf '\n'
  printf ' %s\n' "$(ui_paint muted "账号 ${BUPTY_ACCOUNT} · 共 ${total} 项作业 · ↑↓ 选择 · r 刷新")"

  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf '\n %s\n' "$(ui_paint danger '  加载失败，请查看底部错误信息。')"
    else
      printf '\n %s\n' "$(ui_paint muted '  暂无作业')"
    fi
    return 0
  fi

  if (( total == 0 )); then
    printf '\n %s\n' "$(ui_paint muted '  暂无作业')"
    return 0
  fi

  local visible=$((UI_ROWS - 8))
  if (( visible < 5 )); then visible=5; fi
  if (( ASSIGNMENTS_SEL >= total )); then ASSIGNMENTS_SEL=$((total - 1)); fi
  if (( ASSIGNMENTS_SEL < 0 )); then ASSIGNMENTS_SEL=0; fi
  local offset="${ASSIGNMENTS_OFFSET:-0}"
  if (( ASSIGNMENTS_SEL < offset )); then offset=${ASSIGNMENTS_SEL}; fi
  if (( ASSIGNMENTS_SEL >= offset + visible )); then offset=$((ASSIGNMENTS_SEL - visible + 1)); fi
  ASSIGNMENTS_OFFSET=${offset}
  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  local i
  for ((i = offset; i < end; i++)); do
    _assignments_render_row "${i}"
  done
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染列表或错误。
render_assignments() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _assignments_stale; then
    assignments_fetch
  fi
  _assignments_render_list
}

# 按键处理：↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_assignments_key() {
  local key="$1"
  local total
  case "${key}" in
    UP)
      if (( ASSIGNMENTS_SEL > 0 )); then ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_assignments_count)"
      if (( total > 0 && ASSIGNMENTS_SEL < total - 1 )); then ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL + 1)); fi
      ;;
    PGUP)
      ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL - 10))
      if (( ASSIGNMENTS_SEL < 0 )); then ASSIGNMENTS_SEL=0; fi
      ;;
    PGDN)
      total="$(_assignments_count)"
      ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL + 10))
      if (( total > 0 && ASSIGNMENTS_SEL >= total )); then ASSIGNMENTS_SEL=$((total - 1)); fi
      if (( ASSIGNMENTS_SEL < 0 )); then ASSIGNMENTS_SEL=0; fi
      ;;
    r)
      assignments_refresh
      ;;
  esac
}
