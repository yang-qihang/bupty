#!/usr/bin/env bash
# views/schedule.sh —— 课表视图：学期信息、节次网格（周一到周日）、今天课程列表与滚动选择。

set -euo pipefail

# 视图状态。
SCHEDULE_DATA=""      # 课表 JSON 对象（{term_id, term_start_date, current_week, courses:[]}）。
SCHEDULE_ACCOUNT=""   # 数据所属账号。
SCHEDULE_LOADED=0     # 是否已为当前账号加载过（含失败）。
SCHEDULE_SEL=0        # 今天课程列表选中行。
SCHEDULE_OFFSET=0     # 今天课程列表滚动偏移。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_schedule_stale() {
  [[ "${SCHEDULE_LOADED}" != "1" || "${SCHEDULE_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 今天星期几（1=周一..7=周日）。
_schedule_today() {
  core_weekday "$(core_today)"
}

# 今天的课程数组（按 start_slot、name 升序）。输出 JSON 数组。
_schedule_today_courses() {
  local d
  d="$(_schedule_today)"
  printf '%s' "${SCHEDULE_DATA}" | jq -c --argjson d "${d}" \
    '[.courses[]? | select(.weekday == $d)] | sort_by(.start_slot, .name)' 2>/dev/null || true
}

# 今天课程条数。
_schedule_today_count() {
  local arr n
  arr="$(_schedule_today_courses)"
  n="$(printf '%s' "${arr}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${n}" || "${n}" == "null" ]]; then
    printf '0'
  else
    printf '%s' "${n}"
  fi
}

# 网格某单元格（某天某节）显示的课程名（多门取第一门）。
_schedule_cell_text() {
  local day="$1" slot="$2"
  printf '%s' "${SCHEDULE_DATA}" | jq -r --argjson d "${day}" --argjson s "${slot}" \
    '[.courses[]? | select(.weekday == $d and .start_slot <= $s and .end_slot >= $s)] | .[0].name // ""' 2>/dev/null || true
}

# 拉取并缓存（不渲染）。成功 0，失败置 BUPTY_ERR 且保留旧数据。
schedule_fetch() {
  local tmp data
  tmp="$(mktemp)"
  if sjd_fetch_schedule "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}" > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    SCHEDULE_DATA="${data}"
    SCHEDULE_ACCOUNT="${BUPTY_ACCOUNT}"
    SCHEDULE_LOADED=1
    SCHEDULE_SEL=0
    SCHEDULE_OFFSET=0
    return 0
  fi
  rm -f "${tmp}"
  SCHEDULE_LOADED=1
  SCHEDULE_ACCOUNT="${BUPTY_ACCOUNT}"
  return 1
}

# 刷新（r 键）：先渲染「加载中」，再拉取，再重渲染。
schedule_refresh() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  tui_set_status "正在加载课表…"
  tui_render
  if ! schedule_fetch; then
    return 1
  fi
  tui_set_status "课表已更新。"
  tui_render
  return 0
}

# 重复输出字符 count 次。
_schedule_repeat() {
  local ch="$1" n="$2" i
  for ((i = 0; i < n; i++)); do printf '%s' "${ch}"; done
}

# 节次网格：列 = 周一..周日，行 = 节次区间，今天列高亮。
_schedule_grid() {
  local min_slot="$1" max_slot="$2"
  local today
  today="$(_schedule_today)"
  local lw=6
  local cw=$(( (UI_COLS - 10 - lw) / 7 ))
  if (( cw < 4 )); then cw=4; fi

  local d s

  # 顶部边框。
  printf ' %s' "${_UI_BOX_TL}"
  _schedule_repeat "${_UI_BOX_H}" "${lw}"
  printf '%s' "${_UI_BOX_MT}"
  for d in 1 2 3 4 5 6 7; do
    _schedule_repeat "${_UI_BOX_H}" "${cw}"
    if (( d < 7 )); then printf '%s' "${_UI_BOX_MT}"; fi
  done
  printf '%s\n' "${_UI_BOX_TR}"

  # 表头。
  printf ' %s' "${_UI_BOX_V}"
  printf '%s' "$(ui_paint muted "$(core_fit '节次' "${lw}")")"
  printf '%s' "${_UI_BOX_V}"
  for d in 1 2 3 4 5 6 7; do
    local label
    case "${d}" in
      1) label="周一" ;;
      2) label="周二" ;;
      3) label="周三" ;;
      4) label="周四" ;;
      5) label="周五" ;;
      6) label="周六" ;;
      7) label="周日" ;;
    esac
    if (( d == today )); then
      printf '%s' "$(ui_paint hl "$(core_fit "${label}" "${cw}")")"
    else
      printf '%s' "$(ui_paint muted "$(core_fit "${label}" "${cw}")")"
    fi
    printf '%s' "${_UI_BOX_V}"
  done
  printf '\n'

  # 表头分隔。
  printf ' %s' "${_UI_BOX_ML}"
  _schedule_repeat "${_UI_BOX_H}" "${lw}"
  printf '%s' "${_UI_BOX_MC}"
  for d in 1 2 3 4 5 6 7; do
    _schedule_repeat "${_UI_BOX_H}" "${cw}"
    if (( d < 7 )); then printf '%s' "${_UI_BOX_MC}"; fi
  done
  printf '%s\n' "${_UI_BOX_MR}"

  # 数据行。
  for ((s = min_slot; s <= max_slot; s++)); do
    printf ' %s' "${_UI_BOX_V}"
    printf '%s' "$(core_fit "第$((s + 1))节" "${lw}")"
    printf '%s' "${_UI_BOX_V}"
    for d in 1 2 3 4 5 6 7; do
      local cell fitted
      cell="$(_schedule_cell_text "${d}" "${s}")"
      fitted="$(core_fit "${cell}" "${cw}")"
      if (( d == today )); then
        printf '%s%s%s' "${UI_HL}" "${fitted}" "${UI_RESET}"
      else
        printf '%s' "${fitted}"
      fi
      printf '%s' "${_UI_BOX_V}"
    done
    printf '\n'
  done

  # 底边框。
  printf ' %s' "${_UI_BOX_BL}"
  _schedule_repeat "${_UI_BOX_H}" "${lw}"
  printf '%s' "${_UI_BOX_MB}"
  for d in 1 2 3 4 5 6 7; do
    _schedule_repeat "${_UI_BOX_H}" "${cw}"
    if (( d < 7 )); then printf '%s' "${_UI_BOX_MB}"; fi
  done
  printf '%s\n' "${_UI_BOX_BR}"
}

# 今天课程单行。
_schedule_today_row() {
  local arr="$1" i="$2"
  local row time_range name room week_text
  row="$(printf '%s' "${arr}" | jq -c '.['"${i}"']' 2>/dev/null || true)"
  [[ -z "${row}" || "${row}" == "null" ]] && return 0
  time_range="$(printf '%s' "${row}" | jq -r '.time_range // ""' 2>/dev/null || true)"
  name="$(printf '%s' "${row}" | jq -r '.name // ""' 2>/dev/null || true)"
  room="$(printf '%s' "${row}" | jq -r '.room // ""' 2>/dev/null || true)"
  week_text="$(printf '%s' "${row}" | jq -r '.week_text // ""' 2>/dev/null || true)"

  local line
  if [[ -n "${room}" ]]; then
    line="${time_range} ${name} @${room} · ${week_text}"
  else
    line="${time_range} ${name} · ${week_text}"
  fi

  if [[ "${i}" -eq "${SCHEDULE_SEL}" ]]; then
    printf ' %s\n' "$(ui_paint hl "› $(core_fit "${line}" "$((UI_COLS - 4))")")"
  else
    printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 6))")"
  fi
}

# 今天课程列表（可滚动）。
_schedule_render_today() {
  local arr count
  arr="$(_schedule_today_courses)"
  count="$(_schedule_today_count)"

  printf ' %s\n' "$(ui_paint title '今天课程')"
  if (( count == 0 )); then
    printf ' %s\n' "$(ui_paint muted '  今天没有课')"
    return 0
  fi

  local visible=$((UI_ROWS - 10))
  if (( visible < 4 )); then visible=4; fi
  if (( SCHEDULE_SEL >= count )); then SCHEDULE_SEL=$((count - 1)); fi
  if (( SCHEDULE_SEL < 0 )); then SCHEDULE_SEL=0; fi
  local offset="${SCHEDULE_OFFSET:-0}"
  if (( SCHEDULE_SEL < offset )); then offset=${SCHEDULE_SEL}; fi
  if (( SCHEDULE_SEL >= offset + visible )); then offset=$((SCHEDULE_SEL - visible + 1)); fi
  SCHEDULE_OFFSET=${offset}
  local end=$((offset + visible))
  if (( end > count )); then end=${count}; fi
  local i
  for ((i = offset; i < end; i++)); do
    _schedule_today_row "${arr}" "${i}"
  done
}

# 内容渲染：信息行 + 网格 + 今天课程。
_schedule_render_content() {
  printf '\n'
  if [[ -z "${SCHEDULE_DATA}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger '  加载失败，请查看底部错误信息。')"
    else
      printf ' %s\n' "$(ui_paint muted '  暂无课表。')"
    fi
    return 0
  fi

  local term_id term_start_date current_week
  term_id="$(printf '%s' "${SCHEDULE_DATA}" | jq -r '.term_id // ""' 2>/dev/null || true)"
  term_start_date="$(printf '%s' "${SCHEDULE_DATA}" | jq -r '.term_start_date // ""' 2>/dev/null || true)"
  current_week="$(printf '%s' "${SCHEDULE_DATA}" | jq -r '.current_week // 0' 2>/dev/null || true)"

  local week_disp
  if (( current_week < 1 )); then
    week_disp="第 ${current_week} 周（未开学）"
  else
    week_disp="第 ${current_week} 周"
  fi
  printf ' %s\n' "$(ui_paint muted "学期 ${term_id} · ${week_disp} · 开学 ${term_start_date}")"
  printf '\n'

  local min_slot max_slot
  min_slot="$(printf '%s' "${SCHEDULE_DATA}" | jq -r '[.courses[]?.start_slot] | min // empty' 2>/dev/null || true)"
  max_slot="$(printf '%s' "${SCHEDULE_DATA}" | jq -r '[.courses[]?.end_slot] | max // empty' 2>/dev/null || true)"
  if [[ -z "${min_slot}" || -z "${max_slot}" ]]; then
    printf ' %s\n' "$(ui_paint muted '  本周暂无课程')"
  else
    _schedule_grid "${min_slot}" "${max_slot}"
  fi
  printf '\n'

  _schedule_render_today
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染网格或错误。
render_schedule() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _schedule_stale; then
    schedule_fetch
  fi
  _schedule_render_content
}

# 按键处理：↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_schedule_key() {
  local key="$1"
  local total
  case "${key}" in
    UP)
      if (( SCHEDULE_SEL > 0 )); then SCHEDULE_SEL=$((SCHEDULE_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_schedule_today_count)"
      if (( total > 0 && SCHEDULE_SEL < total - 1 )); then SCHEDULE_SEL=$((SCHEDULE_SEL + 1)); fi
      ;;
    PGUP)
      SCHEDULE_SEL=$((SCHEDULE_SEL - 10))
      if (( SCHEDULE_SEL < 0 )); then SCHEDULE_SEL=0; fi
      ;;
    PGDN)
      total="$(_schedule_today_count)"
      SCHEDULE_SEL=$((SCHEDULE_SEL + 10))
      if (( total > 0 && SCHEDULE_SEL >= total )); then SCHEDULE_SEL=$((total - 1)); fi
      if (( SCHEDULE_SEL < 0 )); then SCHEDULE_SEL=0; fi
      ;;
    r)
      schedule_refresh
      ;;
  esac
}
