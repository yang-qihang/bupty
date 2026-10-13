#!/usr/bin/env bash
# views/schedule.sh —— 课表视图：学期信息、节次网格（周一到周日）、按星期查看课程列表与滚动选择。

set -euo pipefail

# 视图状态。
SCHEDULE_DATA=""      # 课表 JSON 对象（{term_id, term_start_date, current_week, courses:[]}）。
SCHEDULE_ACCOUNT=""   # 数据所属账号。
SCHEDULE_LOADED=0     # 是否已为当前账号加载过（含失败）。
SCHEDULE_SEL=0        # 课程列表选中行。
SCHEDULE_OFFSET=0     # 课程列表滚动偏移。
SCHEDULE_DAY=""       # 查看的星期几（1=周一..7=周日，空=今天）。
SCHEDULE_WEEK=""      # 查看的教学周（空=当前周）。
SCHEDULE_WEEK_MAX="0" # 课表中出现的最大教学周（切周边界）。
SCHEDULE_CELL_TSV=""  # 网格预计算（weekday\tstart_slot\tname，按 courses 顺序逐节展开）。
SCHEDULE_DAY_ROWS=""  # 当前查看日的课程显示行（TSV：time_range、name、room、week_text）。
SCHEDULE_DAY_COUNT=0  # 当前查看日的课程条数。
SCHEDULE_TERM_ID=""
SCHEDULE_TERM_START=""
SCHEDULE_CURRENT_WEEK="0"
SCHEDULE_MIN_SLOT=""
SCHEDULE_MAX_SLOT=""
declare -A SCHEDULE_CELL_MAP=()  # 网格单元格映射（"day-slot" → 课程名），渲染时重建。
declare -A SCHEDULE_DAY_MAP=()    # 各星期课程行映射（"1".."7" → 换行分隔的行串），切周时一次建好。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_schedule_stale() {
  [[ "${SCHEDULE_LOADED}" != "1" || "${SCHEDULE_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 今天星期几（1=周一..7=周日）。
_schedule_today() {
  core_weekday "$(core_today)"
}

# 当前查看的星期几（默认今天）。
_schedule_day() {
  if [[ "${SCHEDULE_DAY:-}" =~ ^[1-7]$ ]]; then
    printf '%s' "${SCHEDULE_DAY}"
  else
    printf '%s' "$(_schedule_today)"
  fi
}

# 当前查看日课程条数。
_schedule_day_count() {
  printf '%s' "${SCHEDULE_DAY_COUNT:-0}"
}

# 预计算学期元信息与切周边界（拉取成功后一次 jq）。
_schedule_precompute() {
  SCHEDULE_TERM_ID=""
  SCHEDULE_TERM_START=""
  SCHEDULE_CURRENT_WEEK="0"
  SCHEDULE_MIN_SLOT=""
  SCHEDULE_MAX_SLOT=""
  SCHEDULE_WEEK_MAX="0"
  if [[ -z "${SCHEDULE_DATA}" ]]; then
    return 0
  fi

  local meta
  meta="$(printf '%s' "${SCHEDULE_DATA}" | jq -r '
    [ (.term_id // ""),
      (.term_start_date // ""),
      ((.current_week // 0) | tostring),
      (([.courses[]?.start_slot] | min // "") | tostring),
      (([.courses[]?.end_slot] | max // "") | tostring),
      (([.courses[]?.week_numbers[]?] | max // 0) | tostring) ]
    | join("\u001f")
  ' 2>/dev/null || true)"
  IFS=$'\x1f' read -r SCHEDULE_TERM_ID SCHEDULE_TERM_START SCHEDULE_CURRENT_WEEK SCHEDULE_MIN_SLOT SCHEDULE_MAX_SLOT SCHEDULE_WEEK_MAX <<< "${meta}"

  # 默认查看当前周；切周边界为 [1, 最大周]。
  if ! [[ "${SCHEDULE_WEEK:-}" =~ ^[0-9]+$ ]]; then
    SCHEDULE_WEEK="${SCHEDULE_CURRENT_WEEK}"
  fi
  if [[ -z "${SCHEDULE_WEEK_MAX}" || "${SCHEDULE_WEEK_MAX}" == "0" ]]; then
    SCHEDULE_WEEK_MAX="${SCHEDULE_CURRENT_WEEK}"
  fi

  _schedule_precompute_week
}

# 预计算当前查看周的网格单元格与当前查看日的课程显示行。
# 在拉取成功、切周（[ / ]）或切星期（←/→）后调用。
_schedule_precompute_week() {
  SCHEDULE_CELL_TSV=""
  SCHEDULE_CELL_MAP=()
  SCHEDULE_DAY_ROWS=""
  SCHEDULE_DAY_COUNT=0
  if [[ -z "${SCHEDULE_DATA}" ]]; then
    return 0
  fi
  local w
  w="${SCHEDULE_WEEK:-${SCHEDULE_CURRENT_WEEK}}"

  SCHEDULE_CELL_TSV="$(printf '%s' "${SCHEDULE_DATA}" | jq -r --argjson w "${w}" '
    .courses[]?
    | select((.weekday | type) == "number" and (.start_slot | type) == "number" and (.end_slot | type) == "number")
    | select(((.week_numbers // []) | index($w)) != null)
    | . as $c
    | range($c.start_slot; $c.end_slot + 1)
    | [ $c.weekday, ., (($c.name // "") | gsub("[\t\r\n]"; " ")) ]
    | join("\u001f")
  ' 2>/dev/null || true)"

  if [[ -n "${SCHEDULE_CELL_TSV}" ]]; then
    local cd cslot cname
    while IFS=$'\x1f' read -r cd cslot cname; do
      [[ -z "${SCHEDULE_CELL_MAP["${cd}-${cslot}"]+x}" ]] && SCHEDULE_CELL_MAP["${cd}-${cslot}"]="${cname}"
    done <<< "${SCHEDULE_CELL_TSV}"
  fi

  # 一次性预计算所有 7 天的课程行（按星期+周过滤），切星期时 O(1) 查找。
  SCHEDULE_DAY_MAP=()
  local line d rest
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    d="${line%%$'\x1f'*}"
    rest="${line#*$'\x1f'}"
    if [[ -z "${SCHEDULE_DAY_MAP[${d}]+x}" ]]; then
      SCHEDULE_DAY_MAP[${d}]="${rest}"
    else
      SCHEDULE_DAY_MAP[${d}]+=$'\n'"${rest}"
    fi
  done < <(printf '%s' "${SCHEDULE_DATA}" | jq -r --argjson w "${w}" '
    [.courses[]?
      | select(.weekday >= 1 and .weekday <= 7)
      | select(((.week_numbers // []) | index($w)) != null)]
    | sort_by(.weekday, .start_slot, .name)
    | .[]
    | [ (.weekday | tostring),
        ((.time_range // "") | gsub("[\t\r\n]"; " ")),
        ((.name // "") | gsub("[\t\r\n]"; " ")),
        ((.room // "") | gsub("[\t\r\n]"; " ")),
        ((.week_text // "") | gsub("[\t\r\n]"; " ")) ]
    | join("\u001f")
  ' 2>/dev/null || true)

  _schedule_day_rows
}

# 从预计算映射里取出当前查看星期的课程行（纯 bash，无 jq）。
_schedule_day_rows() {
  SCHEDULE_DAY_ROWS=""
  SCHEDULE_DAY_COUNT=0
  if [[ -z "${SCHEDULE_DATA}" ]]; then
    return 0
  fi
  local d
  d="$(_schedule_day)"
  SCHEDULE_DAY_ROWS="${SCHEDULE_DAY_MAP[${d}]:-}"
  if [[ -n "${SCHEDULE_DAY_ROWS}" ]]; then
    local -a _rows
    readarray -t _rows <<< "${SCHEDULE_DAY_ROWS}"
    SCHEDULE_DAY_COUNT="${#_rows[@]}"
  fi
}

# 拉取并缓存（不渲染）。成功 0，失败置 BUPTY_ERR 且保留旧数据。
schedule_fetch() {
  # 账号切换时先清空旧账号数据，避免跨账号残留泄漏。
  if [[ "${SCHEDULE_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
    SCHEDULE_DATA=""
    SCHEDULE_CELL_TSV=""
    SCHEDULE_DAY_ROWS=""
    SCHEDULE_DAY_COUNT=0
    SCHEDULE_DAY=""
    SCHEDULE_WEEK=""
    SCHEDULE_SEL=0
    SCHEDULE_OFFSET=0
  fi
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
    _schedule_precompute
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

# 网格某单元格（某天某节）显示的课程名（多门取第一门），纯 bash 查找。
_schedule_cell_text() {
  local day="$1" slot="$2"
  printf '%s' "${SCHEDULE_CELL_MAP["${day}-${slot}"]:-}"
}

# 节次网格：列 = 周一..周日，行 = 节次区间，选中日列高亮、今天列轻标记。
_schedule_grid() {
  local min_slot="$1" max_slot="$2"
  local day_sel today
  day_sel="$(_schedule_day)"
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
  _core_fit_compute '节次' "${lw}"
  printf '%s%s%s' "${UI_MUTED}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  printf '%s' "${_UI_BOX_V}"
  local label flabel
  for d in 1 2 3 4 5 6 7; do
    case "${d}" in
      1) label="周一" ;;
      2) label="周二" ;;
      3) label="周三" ;;
      4) label="周四" ;;
      5) label="周五" ;;
      6) label="周六" ;;
      7) label="周日" ;;
    esac
    _core_fit_compute "${label}" "${cw}"
    flabel="${_CORE_FIT_OUT}"
    if (( d == day_sel )); then
      printf '%s%s%s' "${UI_HL_FG}" "${flabel}" "${UI_RESET}"
    elif (( d == today )); then
      printf '%s%s%s' "${UI_TITLE}" "${flabel}" "${UI_RESET}"
    else
      printf '%s%s%s' "${UI_MUTED}" "${flabel}" "${UI_RESET}"
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
  local cell fitted
  for ((s = min_slot; s <= max_slot; s++)); do
    printf ' %s' "${_UI_BOX_V}"
    _core_fit_compute "第$((s + 1))节" "${lw}"
    printf '%s' "${_CORE_FIT_OUT}"
    printf '%s' "${_UI_BOX_V}"
    for d in 1 2 3 4 5 6 7; do
      cell="${SCHEDULE_CELL_MAP["${d}-${s}"]:-}"
      _core_fit_compute "${cell}" "${cw}"
      fitted="${_CORE_FIT_OUT}"
      if (( d == day_sel )); then
        printf '%s%s%s' "${UI_HL}" "${fitted}" "${UI_RESET}"
      elif (( d == today )); then
        printf '%s%s%s' "${UI_TITLE}" "${fitted}" "${UI_RESET}"
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

# 课程单行。
_schedule_day_row() {
  local i="$1"
  local row="${_SCHEDULE_DAY_ROWS[$i]:-}"
  [[ -z "${row}" ]] && return 0
  # 参数展开切分 TSV，避免 herestring（fork）。
  local time_range name room week_text line rest
  time_range="${row%%$'\x1f'*}"
  rest="${row#*$'\x1f'}"
  name="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  room="${rest%%$'\x1f'*}"
  week_text="${rest#*$'\x1f'}"

  if [[ -n "${room}" ]]; then
    line="${time_range} ${name} @${room} · ${week_text}"
  else
    line="${time_range} ${name} · ${week_text}"
  fi

  if [[ "${i}" -eq "${SCHEDULE_SEL}" ]]; then
    _core_fit_compute "${line}" "$((UI_COLS - 4))"
    printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  else
    _core_fit_compute "${line}" "$((UI_COLS - 6))"
    printf '   %s\n' "${_CORE_FIT_OUT}"
  fi
}

# 课程列表（可滚动）。
_schedule_render_day() {
  local count
  count="$(_schedule_day_count)"

  local d dlabel
  d="$(_schedule_day)"
  case "${d}" in
    1) dlabel="周一" ;;
    2) dlabel="周二" ;;
    3) dlabel="周三" ;;
    4) dlabel="周四" ;;
    5) dlabel="周五" ;;
    6) dlabel="周六" ;;
    7) dlabel="周日" ;;
  esac

  printf ' %s\n' "$(ui_paint title "${dlabel}课程")"
  if (( count == 0 )); then
    printf ' %s\n' "$(ui_paint muted "  ${dlabel}没有课")"
    return 0
  fi

  _SCHEDULE_DAY_ROWS=()
  if [[ -n "${SCHEDULE_DAY_ROWS}" ]]; then
    readarray -t _SCHEDULE_DAY_ROWS <<< "${SCHEDULE_DAY_ROWS}"
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
    _schedule_day_row "${i}"
  done
}

# 内容渲染：信息行 + 网格 + 按星期课程。
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

  local term_id="${SCHEDULE_TERM_ID}" term_start_date="${SCHEDULE_TERM_START}" current_week="${SCHEDULE_CURRENT_WEEK}"
  local sel_week="${SCHEDULE_WEEK:-${current_week}}"

  local week_disp
  if [[ "${sel_week}" != "${current_week}" ]]; then
    week_disp="第 ${sel_week} 周（当前第 ${current_week} 周）"
  elif (( current_week < 1 )); then
    week_disp="第 ${current_week} 周（未开学）"
  else
    week_disp="第 ${current_week} 周"
  fi
  printf ' %s\n' "$(ui_paint muted "$(core_fit "学期 ${term_id} · ${week_disp} · 开学 ${term_start_date} · [ ] 切周" "$((UI_COLS - 2))")")"
  printf '\n'

  if [[ -z "${SCHEDULE_MIN_SLOT}" || -z "${SCHEDULE_MAX_SLOT}" ]]; then
    printf ' %s\n' "$(ui_paint muted '  本周暂无课程')"
  else
    _schedule_grid "${SCHEDULE_MIN_SLOT}" "${SCHEDULE_MAX_SLOT}"
  fi
  printf '\n'

  _schedule_render_day
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染网格或错误。
render_schedule() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _schedule_stale; then
    if [[ -z "${TUI_FETCH_PID}" ]]; then
      if [[ "${SCHEDULE_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
        SCHEDULE_DATA=""; SCHEDULE_CELL_TSV=""; SCHEDULE_CELL_MAP=(); SCHEDULE_DAY_MAP=()
        SCHEDULE_DAY_ROWS=""; SCHEDULE_DAY_COUNT=0; SCHEDULE_DAY=""; SCHEDULE_WEEK=""
        SCHEDULE_SEL=0; SCHEDULE_OFFSET=0
      fi
      _async_start schedule sjd_fetch_schedule "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"
    fi
  fi
  if [[ -z "${SCHEDULE_DATA}" ]]; then
    printf '\n %s\n' "$(ui_paint muted '  正在加载课表…')"
  else
    _schedule_render_content
  fi
}

# 后台拉取完成回调：读取数据并更新视图状态。
apply_schedule() {
  local file="$1" data
  data="$(cat "${file}" 2>/dev/null || true)"
  if [[ "${data}" == ERROR:* ]]; then
    core_err "${data#ERROR:}"
    SCHEDULE_LOADED=1
    SCHEDULE_ACCOUNT="${BUPTY_ACCOUNT}"
    return 0
  fi
  if [[ -n "${data}" ]]; then
    SCHEDULE_DATA="${data}"
    SCHEDULE_ACCOUNT="${BUPTY_ACCOUNT}"
    SCHEDULE_LOADED=1
    SCHEDULE_SEL=0
    SCHEDULE_OFFSET=0
    _schedule_precompute
  else
    core_err "加载失败。"
    SCHEDULE_LOADED=1
    SCHEDULE_ACCOUNT="${BUPTY_ACCOUNT}"
  fi
  return 0
}

# 按键处理：←/→ 切星期、↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_schedule_key() {
  local key="$1"
  local total
  case "${key}" in
    LEFT)
      SCHEDULE_DAY=$(( $( _schedule_day ) - 1 ))
      if (( SCHEDULE_DAY < 1 )); then SCHEDULE_DAY=7; fi
      SCHEDULE_SEL=0
      SCHEDULE_OFFSET=0
      _schedule_day_rows
      ;;
    RIGHT)
      SCHEDULE_DAY=$(( $( _schedule_day ) + 1 ))
      if (( SCHEDULE_DAY > 7 )); then SCHEDULE_DAY=1; fi
      SCHEDULE_SEL=0
      SCHEDULE_OFFSET=0
      _schedule_day_rows
      ;;
    UP)
      if (( SCHEDULE_SEL > 0 )); then SCHEDULE_SEL=$((SCHEDULE_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_schedule_day_count)"
      if (( total > 0 && SCHEDULE_SEL < total - 1 )); then SCHEDULE_SEL=$((SCHEDULE_SEL + 1)); fi
      ;;
    PGUP)
      SCHEDULE_SEL=$((SCHEDULE_SEL - 10))
      if (( SCHEDULE_SEL < 0 )); then SCHEDULE_SEL=0; fi
      ;;
    PGDN)
      total="$(_schedule_day_count)"
      SCHEDULE_SEL=$((SCHEDULE_SEL + 10))
      if (( total > 0 && SCHEDULE_SEL >= total )); then SCHEDULE_SEL=$((total - 1)); fi
      if (( SCHEDULE_SEL < 0 )); then SCHEDULE_SEL=0; fi
      ;;
    '[')
      # 上一周（边界：不低于第 1 周）。
      if (( SCHEDULE_WEEK > 1 )); then
        SCHEDULE_WEEK=$((SCHEDULE_WEEK - 1))
        SCHEDULE_SEL=0
        SCHEDULE_OFFSET=0
        _schedule_precompute_week
      fi
      ;;
    ']')
      # 下一周（边界：不超过课表最大周）。
      if (( SCHEDULE_WEEK < SCHEDULE_WEEK_MAX )); then
        SCHEDULE_WEEK=$((SCHEDULE_WEEK + 1))
        SCHEDULE_SEL=0
        SCHEDULE_OFFSET=0
        _schedule_precompute_week
      fi
      ;;
    r)
      schedule_refresh
      ;;
  esac
}
