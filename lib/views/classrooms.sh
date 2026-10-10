#!/usr/bin/env bash
# views/classrooms.sh —— 空教室视图：两校区切换、楼名筛选、房间空余节次列表与滚动选择。

set -euo pipefail

# 视图状态。
CLASSROOMS_DATA=""       # 空教室 JSON 对象（{target_date, campuses:[{campus_id, campus_name, rooms:[]}]}）。
CLASSROOMS_ACCOUNT=""    # 数据所属账号。
CLASSROOMS_LOADED=0      # 是否已为当前账号加载过（含失败）。
CLASSROOMS_CAMPUS=0      # 当前校区索引（0/1）。
CLASSROOMS_BUILDING=""   # 当前楼筛选，"" 表示全部。
CLASSROOMS_SEL=0         # 房间列表选中行。
CLASSROOMS_OFFSET=0      # 房间列表滚动偏移。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_classrooms_stale() {
  [[ "${CLASSROOMS_LOADED}" != "1" || "${CLASSROOMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 当前校区对象（JSON）。
_classrooms_campus() {
  printf '%s' "${CLASSROOMS_DATA}" | jq -c --argjson i "${CLASSROOMS_CAMPUS}" '.campuses[$i] // {}' 2>/dev/null || true
}

# 当前校区出现过的楼名（每行一个，升序去重）。
_classrooms_buildings() {
  local campus
  campus="$(_classrooms_campus)"
  printf '%s' "${campus}" | jq -r '[.rooms[]?.building] | unique | .[]' 2>/dev/null || true
}

# 当前校区 + 楼筛选后的房间数组（JSON）。
_classrooms_rooms() {
  local campus
  campus="$(_classrooms_campus)"
  if [[ -z "${CLASSROOMS_BUILDING}" ]]; then
    printf '%s' "${campus}" | jq -c '.rooms // []' 2>/dev/null || true
  else
    printf '%s' "${campus}" | jq -c --arg b "${CLASSROOMS_BUILDING}" '[.rooms[]? | select(.building == $b)]' 2>/dev/null || true
  fi
}

# 房间条数。
_classrooms_count() {
  local rooms n
  rooms="$(_classrooms_rooms)"
  n="$(printf '%s' "${rooms}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${n}" || "${n}" == "null" ]]; then
    printf '0'
  else
    printf '%s' "${n}"
  fi
}

# 把 0-based 节次 JSON 数组转为 1-based 紧凑文本（如 "1,2,3"、"1-3"），无节次输出 "满"。
_classrooms_slot_text() {
  local arr="$1"
  local -a slots=()
  local s
  while IFS= read -r s; do slots+=("$((10#$s + 1))"); done < <(printf '%s' "${arr}" | jq -r '.[] | tostring' 2>/dev/null || true)
  if [[ ${#slots[@]} -eq 0 ]]; then
    printf '满'
    return 0
  fi
  local out="" start prev i
  start="${slots[0]}"; prev="${slots[0]}"
  for ((i = 1; i < ${#slots[@]}; i++)); do
    if (( slots[i] == prev + 1 )); then
      prev="${slots[i]}"
    else
      if (( start == prev )); then out+="${start},"; else out+="${start}-${prev},"; fi
      start="${slots[i]}"; prev="${slots[i]}"
    fi
  done
  if (( start == prev )); then out+="${start}"; else out+="${start}-${prev}"; fi
  printf '%s' "${out}"
}

# 拉取并缓存（不渲染）。成功 0，失败置 BUPTY_ERR 且保留旧数据。
classrooms_fetch() {
  local tmp data
  tmp="$(mktemp)"
  if sjd_fetch_classrooms "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}" > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    CLASSROOMS_DATA="${data}"
    CLASSROOMS_ACCOUNT="${BUPTY_ACCOUNT}"
    CLASSROOMS_LOADED=1
    CLASSROOMS_CAMPUS=0
    CLASSROOMS_BUILDING=""
    CLASSROOMS_SEL=0
    CLASSROOMS_OFFSET=0
    return 0
  fi
  rm -f "${tmp}"
  CLASSROOMS_LOADED=1
  CLASSROOMS_ACCOUNT="${BUPTY_ACCOUNT}"
  return 1
}

# 刷新（r 键）：先渲染「加载中」，再拉取，再重渲染。
classrooms_refresh() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  tui_set_status "正在加载空教室…"
  tui_render
  if ! classrooms_fetch; then
    return 1
  fi
  tui_set_status "空教室已更新。"
  tui_render
  return 0
}

# 渲染单行：楼 房间 [容量N] 空节次：…（选中行高亮）。
_classrooms_render_row() {
  local i="$1"
  local row building room size slots slot_text
  row="$(printf '%s' "$(_classrooms_rooms)" | jq -c '.['"${i}"']' 2>/dev/null || true)"
  [[ -z "${row}" || "${row}" == "null" ]] && return 0
  building="$(printf '%s' "${row}" | jq -r '.building // ""' 2>/dev/null || true)"
  room="$(printf '%s' "${row}" | jq -r '.room // ""' 2>/dev/null || true)"
  size="$(printf '%s' "${row}" | jq -r '.size // empty' 2>/dev/null || true)"
  slots="$(printf '%s' "${row}" | jq -c '.available_slots // []' 2>/dev/null || true)"
  slot_text="$(_classrooms_slot_text "${slots}")"

  local cap="" line
  if [[ -n "${size}" && "${size}" != "null" ]]; then
    cap=" [容量${size}]"
  fi
  if [[ "${slot_text}" == "满" ]]; then
    line="${building} ${room}${cap} 满"
  else
    line="${building} ${room}${cap} 空节次：${slot_text}"
  fi

  if [[ "${i}" -eq "${CLASSROOMS_SEL}" ]]; then
    printf ' %s\n' "$(ui_paint hl "› $(core_fit "${line}" "$((UI_COLS - 4))")")"
  else
    printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 6))")"
  fi
}

# 楼筛选行（「全部」+ 各楼，当前项高亮）。
_classrooms_render_building_bar() {
  local -a buildings=()
  local b
  while IFS= read -r b; do [[ -n "${b}" ]] && buildings+=("${b}"); done < <(_classrooms_buildings)
  if [[ ${#buildings[@]} -eq 0 ]]; then
    return 0
  fi

  printf ' %s\n' "$(ui_paint title '楼筛选')"
  local line=""
  local is_cur
  is_cur=0
  [[ -z "${CLASSROOMS_BUILDING}" ]] && is_cur=1
  if (( is_cur )); then
    line+="$(ui_paint hl '全部')"
  else
    line+="$(ui_paint text '全部')"
  fi
  for b in "${buildings[@]}"; do
    if [[ "${b}" == "${CLASSROOMS_BUILDING}" ]]; then
      line+="  $(ui_paint hl "${b}")"
    else
      line+="  $(ui_paint muted "${b}")"
    fi
  done
  printf ' %s\n' "${line}"
}

# 房间列表主体（含信息行与滚动）。
_classrooms_render_list() {
  local total rooms
  total="$(_classrooms_count)"
  rooms="$(_classrooms_rooms)"

  if (( total == 0 )); then
    printf '\n %s\n' "$(ui_paint muted '  当前筛选下暂无空教室。')"
    return 0
  fi

  local visible=$((UI_ROWS - 9))
  if (( visible < 4 )); then visible=4; fi
  if (( CLASSROOMS_SEL >= total )); then CLASSROOMS_SEL=$((total - 1)); fi
  if (( CLASSROOMS_SEL < 0 )); then CLASSROOMS_SEL=0; fi
  local offset="${CLASSROOMS_OFFSET:-0}"
  if (( CLASSROOMS_SEL < offset )); then offset=${CLASSROOMS_SEL}; fi
  if (( CLASSROOMS_SEL >= offset + visible )); then offset=$((CLASSROOMS_SEL - visible + 1)); fi
  CLASSROOMS_OFFSET=${offset}
  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  local i
  for ((i = offset; i < end; i++)); do
    _classrooms_render_row "${i}"
  done
}

# 内容渲染：信息行 + 楼筛选 + 房间列表。
_classrooms_render_content() {
  printf '\n'
  if [[ -z "${CLASSROOMS_DATA}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger '  加载失败，请查看底部错误信息。')"
    else
      printf ' %s\n' "$(ui_paint muted '  暂无空教室数据。')"
    fi
    return 0
  fi

  local target_date campus_name building_disp total
  target_date="$(printf '%s' "${CLASSROOMS_DATA}" | jq -r '.target_date // ""' 2>/dev/null || true)"
  campus_name="$(printf '%s' "${CLASSROOMS_DATA}" | jq -r --argjson i "${CLASSROOMS_CAMPUS}" '.campuses[$i].campus_name // ""' 2>/dev/null || true)"
  building_disp="${CLASSROOMS_BUILDING:-全部}"
  total="$(_classrooms_count)"

  printf ' %s\n' "$(ui_paint muted "空教室 · ${target_date} · 校区 ${campus_name} · 楼 ${building_disp} · 共 ${total} 间 · ←→ 切校区 · f 切楼 · ↑↓ 选择 · r 刷新")"
  printf '\n'
  _classrooms_render_building_bar
  _classrooms_render_list
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染列表或错误。
render_classrooms() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _classrooms_stale; then
    classrooms_fetch
  fi
  _classrooms_render_content
}

# 按键处理：←/→ 切校区、f 循环楼筛选、↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_classrooms_key() {
  local key="$1"
  local total
  case "${key}" in
    LEFT|RIGHT)
      CLASSROOMS_CAMPUS=$(( 1 - CLASSROOMS_CAMPUS ))
      CLASSROOMS_BUILDING=""
      CLASSROOMS_SEL=0
      CLASSROOMS_OFFSET=0
      ;;
    f)
      # 全部 → 各楼 → 全部，循环。
      local -a buildings=()
      local b idx=-1 i=0
      while IFS= read -r b; do [[ -n "${b}" ]] && buildings+=("${b}"); done < <(_classrooms_buildings)
      if [[ ${#buildings[@]} -gt 0 ]]; then
        if [[ -z "${CLASSROOMS_BUILDING}" ]]; then
          CLASSROOMS_BUILDING="${buildings[0]}"
        else
          for b in "${buildings[@]}"; do
            if [[ "${b}" == "${CLASSROOMS_BUILDING}" ]]; then idx=$i; break; fi
            i=$((i + 1))
          done
          if (( idx >= 0 && idx + 1 < ${#buildings[@]} )); then
            CLASSROOMS_BUILDING="${buildings[$((idx + 1))]}"
          else
            CLASSROOMS_BUILDING=""
          fi
        fi
      fi
      CLASSROOMS_SEL=0
      CLASSROOMS_OFFSET=0
      ;;
    UP)
      if (( CLASSROOMS_SEL > 0 )); then CLASSROOMS_SEL=$((CLASSROOMS_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_classrooms_count)"
      if (( total > 0 && CLASSROOMS_SEL < total - 1 )); then CLASSROOMS_SEL=$((CLASSROOMS_SEL + 1)); fi
      ;;
    PGUP)
      CLASSROOMS_SEL=$((CLASSROOMS_SEL - 10))
      if (( CLASSROOMS_SEL < 0 )); then CLASSROOMS_SEL=0; fi
      ;;
    PGDN)
      total="$(_classrooms_count)"
      CLASSROOMS_SEL=$((CLASSROOMS_SEL + 10))
      if (( total > 0 && CLASSROOMS_SEL >= total )); then CLASSROOMS_SEL=$((total - 1)); fi
      if (( CLASSROOMS_SEL < 0 )); then CLASSROOMS_SEL=0; fi
      ;;
    r)
      classrooms_refresh
      ;;
  esac
}
