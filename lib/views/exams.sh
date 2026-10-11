#!/usr/bin/env bash
# views/exams.sh —— 考试安排视图：按日期/时间升序列表、滚动选择。

set -euo pipefail

# 视图状态。
EXAMS_DATA=""      # 考试安排 JSON 对象（{term_id, items:[{id,name,date,start_time,end_time,room,time_text}]}）。
EXAMS_ACCOUNT=""   # 数据所属账号。
EXAMS_LOADED=0     # 是否已为当前账号加载过（含失败）。
EXAMS_SEL=0        # 列表选中行。
EXAMS_OFFSET=0     # 列表滚动偏移。
EXAMS_ROWS=""      # 预计算考试显示行（每行一个完整文本行）。
EXAMS_COUNT=0      # 预计算条数。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_exams_stale() {
  [[ "${EXAMS_LOADED}" != "1" || "${EXAMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 考试条目数。
_exams_count() {
  if [[ -z "${EXAMS_DATA}" ]]; then
    printf '0'
  else
    printf '%s' "${EXAMS_COUNT:-0}"
  fi
}

# 预计算考试显示行（拉取成功后一次 jq，按 date/start_time 升序）。
_exams_precompute() {
  EXAMS_ROWS=""
  EXAMS_COUNT=0
  if [[ -z "${EXAMS_DATA}" ]]; then
    return 0
  fi
  EXAMS_ROWS="$(printf '%s' "${EXAMS_DATA}" | jq -r '
    [.items[]?] | sort_by(.date, .start_time)
    | .[]
    | (.date // "") as $date
    | (.start_time // "") as $start
    | (.end_time // "") as $end
    | (.name // "") as $name
    | (.room // "") as $room
    | (.time_text // "") as $time_text
    | (if ($date != "" and $start != "") then
         ($date + " " + $start + "-" + $end + " " + $name + (if $room != "" then " @" + $room else "" end))
       else
         ("时间待定 " + $name + (if $time_text != "" then " · " + $time_text else "" end))
       end)
    | gsub("[\t\r\n]"; " ")
  ' 2>/dev/null || true)"
  if [[ -n "${EXAMS_ROWS}" ]]; then
    EXAMS_COUNT="$(wc -l <<< "${EXAMS_ROWS}" 2>/dev/null || echo 0)"
    EXAMS_COUNT="${EXAMS_COUNT//[^0-9]/}"
  fi
}

# 拉取当前学期考试安排并缓存。成功 0，失败置 BUPTY_ERR 且保留旧数据。
exams_fetch() {
  # 账号切换时先清空旧账号数据，避免跨账号残留泄漏。
  if [[ "${EXAMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
    EXAMS_DATA=""
    EXAMS_ROWS=""
    EXAMS_COUNT=0
    EXAMS_SEL=0
    EXAMS_OFFSET=0
  fi
  local tmp term_id
  tmp="$(mktemp)"
  if ! sjd_fetch_grade_terms "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}" > "${tmp}"; then
    rm -f "${tmp}"
    EXAMS_LOADED=1
    EXAMS_ACCOUNT="${BUPTY_ACCOUNT}"
    return 1
  fi
  term_id="$(printf '%s' "$(cat "${tmp}")" | jq -r '.current_term_id // empty' 2>/dev/null || true)"
  rm -f "${tmp}"
  if [[ -z "${term_id}" ]]; then
    core_err "教务未返回当前学期。"
    EXAMS_LOADED=1
    EXAMS_ACCOUNT="${BUPTY_ACCOUNT}"
    return 1
  fi

  tmp="$(mktemp)"
  if ! sjd_fetch_exams "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}" "${term_id}" > "${tmp}"; then
    rm -f "${tmp}"
    EXAMS_LOADED=1
    EXAMS_ACCOUNT="${BUPTY_ACCOUNT}"
    return 1
  fi
  EXAMS_DATA="$(cat "${tmp}")"
  rm -f "${tmp}"
  EXAMS_LOADED=1
  EXAMS_ACCOUNT="${BUPTY_ACCOUNT}"
  EXAMS_SEL=0
  EXAMS_OFFSET=0
  _exams_precompute
  return 0
}

# 刷新（r 键）：先渲染「加载中」，再拉取，再重渲染。
exams_refresh() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  tui_set_status "正在加载考试安排…"
  tui_render
  if ! exams_fetch; then
    return 1
  fi
  tui_set_status "考试安排已更新。"
  tui_render
  return 0
}

# 渲染单行：日期 HH:MM-HH:MM 课程 @考场；时间待定时显示「时间待定」+ 原始 time_text。
_exams_render_row() {
  local i="$1"
  local line="${_EXAMS_ROWS[$i]:-}"
  [[ -z "${line}" ]] && return 0

  if [[ "${i}" -eq "${EXAMS_SEL}" ]]; then
    printf ' %s\n' "$(ui_paint hl "› $(core_fit "${line}" "$((UI_COLS - 4))")")"
  else
    printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 6))")"
  fi
}

# 内容渲染：信息行 + 考试列表。
_exams_render_content() {
  printf '\n'
  if [[ -z "${EXAMS_DATA}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger '  加载失败，请查看底部错误信息。')"
    else
      printf ' %s\n' "$(ui_paint muted '  暂无考试数据。')"
    fi
    return 0
  fi

  local term_id total
  term_id="$(printf '%s' "${EXAMS_DATA}" | jq -r '.term_id // ""' 2>/dev/null || true)"
  total="$(_exams_count)"
  printf ' %s\n' "$(ui_paint muted "考试安排 · ${term_id} · 共 ${total} 场 · ↑↓ 选择 · r 刷新")"
  printf '\n'

  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted '  暂无考试')"
    return 0
  fi

  # 纯 bash 读入预计算行，渲染循环内不再有任何 jq。
  _EXAMS_ROWS=()
  if [[ -n "${EXAMS_ROWS}" ]]; then
    readarray -t _EXAMS_ROWS <<< "${EXAMS_ROWS}"
  fi

  local visible=$((UI_ROWS - 8))
  if (( visible < 4 )); then visible=4; fi
  if (( EXAMS_SEL >= total )); then EXAMS_SEL=$((total - 1)); fi
  if (( EXAMS_SEL < 0 )); then EXAMS_SEL=0; fi
  local offset="${EXAMS_OFFSET:-0}"
  if (( EXAMS_SEL < offset )); then offset=${EXAMS_SEL}; fi
  if (( EXAMS_SEL >= offset + visible )); then offset=$((EXAMS_SEL - visible + 1)); fi
  EXAMS_OFFSET=${offset}
  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  local i
  for ((i = offset; i < end; i++)); do
    _exams_render_row "${i}"
  done
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染列表或错误。
render_exams() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _exams_stale; then
    printf ' %s\n' "$(ui_paint muted '  正在加载…')"
    exams_fetch
    ui_erase_prev_line
  fi
  _exams_render_content
}

# 按键处理：↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_exams_key() {
  local key="$1"
  local total
  case "${key}" in
    UP)
      if (( EXAMS_SEL > 0 )); then EXAMS_SEL=$((EXAMS_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_exams_count)"
      if (( total > 0 && EXAMS_SEL < total - 1 )); then EXAMS_SEL=$((EXAMS_SEL + 1)); fi
      ;;
    PGUP)
      EXAMS_SEL=$((EXAMS_SEL - 10))
      if (( EXAMS_SEL < 0 )); then EXAMS_SEL=0; fi
      ;;
    PGDN)
      total="$(_exams_count)"
      EXAMS_SEL=$((EXAMS_SEL + 10))
      if (( total > 0 && EXAMS_SEL >= total )); then EXAMS_SEL=$((total - 1)); fi
      if (( EXAMS_SEL < 0 )); then EXAMS_SEL=0; fi
      ;;
    r)
      exams_refresh
      ;;
  esac
}
