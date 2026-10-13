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
CLASSROOMS_CAMPUS0_ROWS=""  # 预计算校区 0 房间行（TSV：building、room、size、slot_text）。
CLASSROOMS_CAMPUS1_ROWS=""  # 预计算校区 1 房间行。
CLASSROOMS_CAMPUS0_BUILDINGS=""  # 预计算校区 0 楼名（每行一个，升序去重）。
CLASSROOMS_CAMPUS1_BUILDINGS=""  # 预计算校区 1 楼名。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_classrooms_stale() {
  [[ "${CLASSROOMS_LOADED}" != "1" || "${CLASSROOMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 预计算两个校区的房间行与楼名（拉取成功后调用）。
_classrooms_precompute() {
  CLASSROOMS_CAMPUS0_ROWS=""
  CLASSROOMS_CAMPUS1_ROWS=""
  CLASSROOMS_CAMPUS0_BUILDINGS=""
  CLASSROOMS_CAMPUS1_BUILDINGS=""
  if [[ -z "${CLASSROOMS_DATA}" ]]; then
    return 0
  fi
  local i rows buildings
  for i in 0 1; do
    rows="$(printf '%s' "${CLASSROOMS_DATA}" | jq -r --argjson i "${i}" '
      def compact:
        if length == 0 then "满"
        else
          (map(. + 1)) as $slots
          | {out: "", start: $slots[0], prev: $slots[0]}
          | reduce $slots[1:][] as $s (.;
              if $s == .prev + 1 then .prev = $s
              else
                (if .start == .prev then .out += (.start | tostring) + ","
                 else .out += (.start | tostring) + "-" + (.prev | tostring) + "," end)
                | .start = $s | .prev = $s
              end)
          | (if .start == .prev then .out += (.start | tostring)
             else .out += (.start | tostring) + "-" + (.prev | tostring) end)
          | .out
        end;
      (.campuses[$i].rooms // []) as $rooms
      | $rooms[]
      | (.building // "") as $building
      | (.room // "") as $room
      | (.size // "") as $size
      | (.available_slots // []) as $slots
      | [ ($building | gsub("[\t\r\n]"; " ")),
          ($room | gsub("[\t\r\n]"; " ")),
          ($size | tostring),
          ($slots | compact) ]
      | join("\u001f")
    ' 2>/dev/null || true)"
    buildings="$(printf '%s' "${CLASSROOMS_DATA}" | jq -r --argjson i "${i}" \
      '[.campuses[$i].rooms[]?.building] | unique | .[]' 2>/dev/null || true)"
    if (( i == 0 )); then
      CLASSROOMS_CAMPUS0_ROWS="${rows}"
      CLASSROOMS_CAMPUS0_BUILDINGS="${buildings}"
    else
      CLASSROOMS_CAMPUS1_ROWS="${rows}"
      CLASSROOMS_CAMPUS1_BUILDINGS="${buildings}"
    fi
  done
}

# 当前校区 + 楼筛选后的房间行（纯 bash 过滤），输出到 _CLASSROOMS_ROWS 并设置 _CLASSROOMS_COUNT。
_classrooms_filtered() {
  _CLASSROOMS_ROWS=()
  _CLASSROOMS_COUNT=0
  local src
  if (( CLASSROOMS_CAMPUS == 0 )); then
    src="${CLASSROOMS_CAMPUS0_ROWS}"
  else
    src="${CLASSROOMS_CAMPUS1_ROWS}"
  fi
  if [[ -z "${src}" ]]; then
    return 0
  fi
  local -a all=()
  readarray -t all <<< "${src}"
  local i building
  for ((i = 0; i < ${#all[@]}; i++)); do
    IFS=$'\x1f' read -r building _ <<< "${all[$i]}"
    if [[ -z "${CLASSROOMS_BUILDING}" || "${building}" == "${CLASSROOMS_BUILDING}" ]]; then
      _CLASSROOMS_ROWS+=("${all[$i]}")
    fi
  done
  _CLASSROOMS_COUNT="${#_CLASSROOMS_ROWS[@]}"
}

# 当前校区楼名（每行一个，末尾补换行，避免 while read 丢末行）。
_classrooms_buildings() {
  if (( CLASSROOMS_CAMPUS == 0 )); then
    [[ -n "${CLASSROOMS_CAMPUS0_BUILDINGS}" ]] && printf '%s\n' "${CLASSROOMS_CAMPUS0_BUILDINGS}"
  else
    [[ -n "${CLASSROOMS_CAMPUS1_BUILDINGS}" ]] && printf '%s\n' "${CLASSROOMS_CAMPUS1_BUILDINGS}"
  fi
}

# 房间条数。
_classrooms_count() {
  _classrooms_filtered
  printf '%s' "${_CLASSROOMS_COUNT}"
}

# 拉取并缓存（不渲染）。成功 0，失败置 BUPTY_ERR 且保留旧数据。
classrooms_fetch() {
  # 账号切换时先清空旧账号数据，避免跨账号残留泄漏。
  if [[ "${CLASSROOMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
    CLASSROOMS_DATA=""
    CLASSROOMS_CAMPUS0_ROWS=""
    CLASSROOMS_CAMPUS1_ROWS=""
    CLASSROOMS_CAMPUS0_BUILDINGS=""
    CLASSROOMS_CAMPUS1_BUILDINGS=""
    CLASSROOMS_CAMPUS=0
    CLASSROOMS_BUILDING=""
    CLASSROOMS_SEL=0
    CLASSROOMS_OFFSET=0
  fi
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
    _classrooms_precompute
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
  local row="${_CLASSROOMS_ROWS[$i]:-}"
  [[ -z "${row}" ]] && return 0
  # 参数展开切分 TSV，避免每条一次 herestring（fork）。
  local building room size slot_text rest
  building="${row%%$'\x1f'*}"
  rest="${row#*$'\x1f'}"
  room="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  size="${rest%%$'\x1f'*}"
  slot_text="${rest#*$'\x1f'}"

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
    _core_fit_compute "${line}" "$((UI_COLS - 4))"
    printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  else
    _core_fit_compute "${line}" "$((UI_COLS - 6))"
    printf '   %s\n' "${_CORE_FIT_OUT}"
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
  # 在当前 shell 直接过滤（不能用 $(...) 包一层，否则会丢 _CLASSROOMS_ROWS）。
  _classrooms_filtered
  local total="${_CLASSROOMS_COUNT}"

  if (( total == 0 )); then
    printf '\n %s\n' "$(ui_paint muted '  当前筛选下暂无空教室。')"
    return 0
  fi

  # 顶部固定行：页眉+分隔(2) + 空行+标题+信息行+空行+楼筛选两行(6) + 底部三行(3) = 11。
  local visible=$((UI_ROWS - 11))
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
  printf ' %s\n' "$(ui_paint title '空教室')"
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
  _classrooms_filtered
  total="${_CLASSROOMS_COUNT}"

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
    if [[ -z "${TUI_FETCH_PID}" ]]; then
      if [[ "${CLASSROOMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
        CLASSROOMS_DATA=""; CLASSROOMS_CAMPUS0_ROWS=""; CLASSROOMS_CAMPUS1_ROWS=""
        CLASSROOMS_CAMPUS0_BUILDINGS=""; CLASSROOMS_CAMPUS1_BUILDINGS=""
        CLASSROOMS_CAMPUS=0; CLASSROOMS_BUILDING=""; CLASSROOMS_SEL=0; CLASSROOMS_OFFSET=0
      fi
      _async_start classrooms sjd_fetch_classrooms "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"
    fi
  fi
  if [[ -z "${CLASSROOMS_DATA}" ]]; then
    printf '\n %s\n' "$(ui_paint muted '  正在加载空教室…')"
  else
    _classrooms_render_content
  fi
}

# 后台拉取完成回调：读取数据并更新视图状态。
apply_classrooms() {
  local file="$1" data
  data="$(cat "${file}" 2>/dev/null || true)"
  if [[ "${data}" == ERROR:* ]]; then
    core_err "${data#ERROR:}"
    CLASSROOMS_LOADED=1
    CLASSROOMS_ACCOUNT="${BUPTY_ACCOUNT}"
    return 0
  fi
  if [[ -n "${data}" ]]; then
    CLASSROOMS_DATA="${data}"
    CLASSROOMS_ACCOUNT="${BUPTY_ACCOUNT}"
    CLASSROOMS_LOADED=1
    CLASSROOMS_CAMPUS=0
    CLASSROOMS_BUILDING=""
    CLASSROOMS_SEL=0
    CLASSROOMS_OFFSET=0
    _classrooms_precompute
  else
    core_err "加载失败。"
    CLASSROOMS_LOADED=1
    CLASSROOMS_ACCOUNT="${BUPTY_ACCOUNT}"
  fi
  return 0
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
