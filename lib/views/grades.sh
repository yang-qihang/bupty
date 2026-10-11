#!/usr/bin/env bash
# views/grades.sh —— 成绩视图：学期切换、记录类型切换、平均绩点与成绩列表滚动选择。

set -euo pipefail

# 视图状态。
GRADES_TERMS=""         # 学期列表 JSON（{current_term_id, terms:[{id,name}]}）。
GRADES_SEL_TERM=0       # 当前选中学期下标。
GRADES_RECORD_TYPE="1"  # 记录类型：1=最好、0=首次、""=全部。
GRADES_DATA=""          # 当前成绩报告（{term_id, record_type, average_grade_point, items:[]}）。
GRADES_ACCOUNT=""       # 数据所属账号。
GRADES_LOADED=0         # 是否已为当前账号加载过（含失败）。
GRADES_SEL=0            # 成绩列表选中行。
GRADES_OFFSET=0         # 成绩列表滚动偏移。
GRADES_ROWS=""          # 预计算成绩显示行（每行一个完整文本行）。
GRADES_COUNT=0          # 预计算条数。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_grades_stale() {
  [[ "${GRADES_LOADED}" != "1" || "${GRADES_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 当前选中学期 id。
_grades_term_id() {
  printf '%s' "${GRADES_TERMS}" | jq -r --argjson i "${GRADES_SEL_TERM}" '.terms[$i].id // empty' 2>/dev/null || true
}

# 当前选中学期显示名。
_grades_term_name() {
  local n
  n="$(printf '%s' "${GRADES_TERMS}" | jq -r --argjson i "${GRADES_SEL_TERM}" '.terms[$i].name // .terms[$i].id // empty' 2>/dev/null || true)"
  if [[ -z "${n}" ]]; then
    n="$(_grades_term_id)"
  fi
  printf '%s' "${n}"
}

# 记录类型显示名。
_grades_record_type_name() {
  case "${GRADES_RECORD_TYPE}" in
    0) printf '首次' ;;
    "") printf '全部' ;;
    *) printf '最好' ;;
  esac
}

# 成绩条目数。
_grades_count() {
  if [[ -z "${GRADES_DATA}" ]]; then
    printf '0'
  else
    printf '%s' "${GRADES_COUNT:-0}"
  fi
}

# 预计算成绩显示行（拉取成绩报告成功后一次 jq）。
_grades_precompute() {
  GRADES_ROWS=""
  GRADES_COUNT=0
  if [[ -z "${GRADES_DATA}" ]]; then
    return 0
  fi
  GRADES_ROWS="$(printf '%s' "${GRADES_DATA}" | jq -r '
    .items // [] | .[]
    | (.name // "") as $name
    | (.credits // "") as $credits
    | (.score // "") as $score
    | (.course_nature // "") as $nature
    | (.grade_status // "") as $status
    | (($name | gsub("[\t\r\n]"; " "))
       + (if ($credits == "") then "" else " [学分" + ($credits | tostring) + "]" end)
       + (if ($score == "") then "" else " " + ($score | tostring) end)
       + (if ($nature == "") then "" else " · " + ($nature | gsub("[\t\r\n]"; " ")) end)
       + (if ($status == "") then "" else " · " + ($status | gsub("[\t\r\n]"; " ")) end))
  ' 2>/dev/null || true)"
  if [[ -n "${GRADES_ROWS}" ]]; then
    GRADES_COUNT="$(wc -l <<< "${GRADES_ROWS}" 2>/dev/null || echo 0)"
    GRADES_COUNT="${GRADES_COUNT//[^0-9]/}"
  fi
}

# 保证选中学期下标有效；无效则回落到当前学期。
_grades_ensure_sel_term() {
  local count cur idx i
  count="$(printf '%s' "${GRADES_TERMS}" | jq -r 'if (.terms | type) == "array" then (.terms | length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${count}" || "${count}" == "null" ]]; then count=0; fi
  if [[ "${GRADES_SEL_TERM:-}" =~ ^[0-9]+$ ]] && (( GRADES_SEL_TERM < count )); then
    return 0
  fi
  cur="$(printf '%s' "${GRADES_TERMS}" | jq -r '.current_term_id // empty' 2>/dev/null || true)"
  idx=-1
  for ((i = 0; i < count; i++)); do
    if [[ "$(printf '%s' "${GRADES_TERMS}" | jq -r --argjson j "${i}" '.terms[$j].id // ""' 2>/dev/null || true)" == "${cur}" ]]; then
      idx=$i
      break
    fi
  done
  if (( idx >= 0 )); then GRADES_SEL_TERM="${idx}"; else GRADES_SEL_TERM=0; fi
}

# 拉取当前选中学期 + 记录类型的成绩报告（不拉学期列表）。
grades_fetch_report() {
  local term_id tmp
  term_id="$(_grades_term_id)"
  if [[ -z "${term_id}" ]]; then
    core_err "暂无可用学期。"
    return 1
  fi
  tmp="$(mktemp)"
  if sjd_fetch_grades "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}" "${term_id}" "${GRADES_RECORD_TYPE}" > "${tmp}"; then
    GRADES_DATA="$(cat "${tmp}")"
    rm -f "${tmp}"
    GRADES_SEL=0
    GRADES_OFFSET=0
    _grades_precompute
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# 拉取学期列表 + 当前选中学期成绩并缓存。成功 0，失败置 BUPTY_ERR 且保留旧数据。
grades_fetch() {
  # 账号切换时先清空旧账号数据，避免跨账号残留泄漏。
  if [[ "${GRADES_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
    GRADES_TERMS=""
    GRADES_DATA=""
    GRADES_ROWS=""
    GRADES_COUNT=0
    GRADES_SEL_TERM=0
    GRADES_SEL=0
    GRADES_OFFSET=0
  fi
  local tmp
  tmp="$(mktemp)"
  if ! sjd_fetch_grade_terms "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}" > "${tmp}"; then
    rm -f "${tmp}"
    GRADES_LOADED=1
    GRADES_ACCOUNT="${BUPTY_ACCOUNT}"
    return 1
  fi
  GRADES_TERMS="$(cat "${tmp}")"
  rm -f "${tmp}"
  _grades_ensure_sel_term
  if ! grades_fetch_report; then
    GRADES_LOADED=1
    GRADES_ACCOUNT="${BUPTY_ACCOUNT}"
    return 1
  fi
  GRADES_LOADED=1
  GRADES_ACCOUNT="${BUPTY_ACCOUNT}"
  return 0
}

# 刷新（r 键）：先渲染「加载中」，再拉取，再重渲染。
grades_refresh() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  tui_set_status "正在加载成绩…"
  tui_render
  if ! grades_fetch; then
    return 1
  fi
  tui_set_status "成绩已更新。"
  tui_render
  return 0
}

# 渲染单行：课程名 [学分X] 成绩 · 性质 · 状态（选中行高亮）。
_grades_render_row() {
  local i="$1"
  local line="${_GRADES_ROWS[$i]:-}"
  [[ -z "${line}" ]] && return 0

  if [[ "${i}" -eq "${GRADES_SEL}" ]]; then
    printf ' %s\n' "$(ui_paint hl "› $(core_fit "${line}" "$((UI_COLS - 4))")")"
  else
    printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 6))")"
  fi
}

# 内容渲染：信息行 + 成绩列表。
_grades_render_content() {
  printf '\n'
  if [[ -z "${GRADES_DATA}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger '  加载失败，请查看底部错误信息。')"
    else
      printf ' %s\n' "$(ui_paint muted '  暂无成绩数据。')"
    fi
    return 0
  fi

  local term_name record_name avg total avg_disp
  term_name="$(_grades_term_name)"
  record_name="$(_grades_record_type_name)"
  avg="$(printf '%s' "${GRADES_DATA}" | jq -r '.average_grade_point // ""' 2>/dev/null || true)"
  total="$(_grades_count)"
  avg_disp="${avg:-—}"
  printf ' %s\n' "$(ui_paint muted "学期 ${term_name} · 记录类型 ${record_name} · 平均绩点 ${avg_disp} · 共 ${total} 条 · t 切学期 · p 切类型 · ↑↓ 选择 · r 刷新")"
  printf '\n'

  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted '  该学期暂无成绩')"
    return 0
  fi

  # 纯 bash 读入预计算行，渲染循环内不再有任何 jq。
  _GRADES_ROWS=()
  if [[ -n "${GRADES_ROWS}" ]]; then
    readarray -t _GRADES_ROWS <<< "${GRADES_ROWS}"
  fi

  local visible=$((UI_ROWS - 8))
  if (( visible < 4 )); then visible=4; fi
  if (( GRADES_SEL >= total )); then GRADES_SEL=$((total - 1)); fi
  if (( GRADES_SEL < 0 )); then GRADES_SEL=0; fi
  local offset="${GRADES_OFFSET:-0}"
  if (( GRADES_SEL < offset )); then offset=${GRADES_SEL}; fi
  if (( GRADES_SEL >= offset + visible )); then offset=$((GRADES_SEL - visible + 1)); fi
  GRADES_OFFSET=${offset}
  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  local i
  for ((i = offset; i < end; i++)); do
    _grades_render_row "${i}"
  done
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染列表或错误。
render_grades() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _grades_stale; then
    grades_fetch
  fi
  _grades_render_content
}

# 按键处理：t 切学期、p 切记录类型、↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_grades_key() {
  local key="$1"
  local total count old
  case "${key}" in
    t)
      count="$(printf '%s' "${GRADES_TERMS}" | jq -r 'if (.terms | type) == "array" then (.terms | length | tostring) else "0" end' 2>/dev/null || true)"
      if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 1 )); then
        old="${GRADES_SEL_TERM}"
        GRADES_SEL_TERM=$(( (GRADES_SEL_TERM + 1) % count ))
        if ! grades_fetch_report; then
          GRADES_SEL_TERM="${old}"
        fi
      fi
      ;;
    p)
      old="${GRADES_RECORD_TYPE}"
      case "${GRADES_RECORD_TYPE}" in
        1) GRADES_RECORD_TYPE="0" ;;
        0) GRADES_RECORD_TYPE="" ;;
        *) GRADES_RECORD_TYPE="1" ;;
      esac
      if ! grades_fetch_report; then
        GRADES_RECORD_TYPE="${old}"
      fi
      ;;
    UP)
      if (( GRADES_SEL > 0 )); then GRADES_SEL=$((GRADES_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_grades_count)"
      if (( total > 0 && GRADES_SEL < total - 1 )); then GRADES_SEL=$((GRADES_SEL + 1)); fi
      ;;
    PGUP)
      GRADES_SEL=$((GRADES_SEL - 10))
      if (( GRADES_SEL < 0 )); then GRADES_SEL=0; fi
      ;;
    PGDN)
      total="$(_grades_count)"
      GRADES_SEL=$((GRADES_SEL + 10))
      if (( total > 0 && GRADES_SEL >= total )); then GRADES_SEL=$((total - 1)); fi
      if (( GRADES_SEL < 0 )); then GRADES_SEL=0; fi
      ;;
    r)
      grades_refresh
      ;;
  esac
}
