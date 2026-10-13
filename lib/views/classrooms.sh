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
CLASSROOMS_SLOT=""       # 时段筛选："" 全部，否则 0..13（0-based 节次）。
CLASSROOMS_FLOOR=""      # 楼层筛选："" 全部，否则房间号首个数字。
CLASSROOMS_HIDDEN=""     # 隐藏教室键（每行一个 building|room）。
CLASSROOMS_HIDDEN_LOADED=0  # 隐藏列表是否已从设置加载。
CLASSROOMS_SHOW_HIDDEN=0 # 是否显示已隐藏教室（H 键切换，用于取消隐藏）。
CLASSROOMS_CAMPUS0_ROWS=""  # 预计算校区 0 房间行（TSV：building、room、size、slots、slot_text）。
CLASSROOMS_CAMPUS1_ROWS=""  # 预计算校区 1 房间行。
CLASSROOMS_CAMPUS0_BUILDINGS=""  # 预计算校区 0 楼名（每行一个，升序去重）。
CLASSROOMS_CAMPUS1_BUILDINGS=""  # 预计算校区 1 楼名。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_classrooms_stale() {
  [[ "${CLASSROOMS_LOADED}" != "1" || "${CLASSROOMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# ---------------------------------------------------------------------------
# 纯函数：时段映射 / 楼层提取 / 节次集合判断（供预计算、筛选与单测复用）
# ---------------------------------------------------------------------------

# 节次下标 → 开始时刻 HH:MM（越界/非数字返回空）。
_classrooms_slot_start() {
  local i="$1"
  if [[ "${i}" =~ ^[0-9]+$ ]] && (( i >= 0 && i < ${#SLOT_TIMES[@]} )); then
    printf '%s' "${SLOT_TIMES[$i]%%|*}"
  fi
}

# 节次下标 → 结束时刻 HH:MM（越界/非数字返回空）。
_classrooms_slot_end() {
  local i="$1"
  if [[ "${i}" =~ ^[0-9]+$ ]] && (( i >= 0 && i < ${#SLOT_TIMES[@]} )); then
    printf '%s' "${SLOT_TIMES[$i]##*|}"
  fi
}

# 节次下标 → 单节友好标签 HH:MM-HH:MM（越界/非数字返回空）。
_classrooms_slot_label() {
  local i="$1"
  if [[ "${i}" =~ ^[0-9]+$ ]] && (( i >= 0 && i < ${#SLOT_TIMES[@]} )); then
    printf '%s' "${SLOT_TIMES[$i]//|/-}"
  fi
}

# 逗号分隔的 0-based 节次 → 友好时段文本（连续节次合并为 HH:MM-HH:MM）。
_classrooms_slot_text() {
  local slots="$1"
  if [[ -z "${slots}" ]]; then
    printf '满'
    return 0
  fi
  local -a arr=()
  local IFS=,
  read -ra arr <<< "${slots}"
  local out="" start=-1 prev=-1 n s
  for s in "${arr[@]}"; do
    [[ "${s}" =~ ^[0-9]+$ ]] || continue
    n=$((10#$s))
    if (( prev >= 0 && n == prev + 1 )); then
      prev=$n
    else
      if (( start >= 0 )); then
        [[ -n "${out}" ]] && out+=","
        out+="$(_classrooms_slot_start "${start}")-$(_classrooms_slot_end "${prev}")"
      fi
      start=$n
      prev=$n
    fi
  done
  if (( start >= 0 )); then
    [[ -n "${out}" ]] && out+=","
    out+="$(_classrooms_slot_start "${start}")-$(_classrooms_slot_end "${prev}")"
  fi
  printf '%s' "${out}"
}

# 房间号首数字（楼层）。如 101→1、202-203→2、N415→4；无数字返回空。
_classrooms_floor_of() {
  local room="$1" i ch
  for ((i = 0; i < ${#room}; i++)); do
    ch="${room:i:1}"
    if [[ "${ch}" =~ [0-9] ]]; then
      printf '%s' "${ch}"
      return 0
    fi
  done
  printf ''
  return 0
}

# 逗号分隔的节次集合是否包含指定节次。包含返回 0。
_classrooms_has_slot() {
  local slots="$1" want="$2"
  if [[ -z "${slots}" ]]; then
    return 1
  fi
  local rest="${slots}" tok
  while [[ -n "${rest}" ]]; do
    if [[ "${rest}" == *","* ]]; then
      tok="${rest%%,*}"
      rest="${rest#*,}"
    else
      tok="${rest}"
      rest=""
    fi
    [[ "${tok}" == "${want}" ]] && return 0
  done
  return 1
}

# 键 building|room 是否已隐藏。
_classrooms_is_hidden() {
  local key="$1"
  if [[ -z "${CLASSROOMS_HIDDEN}" ]]; then
    return 1
  fi
  # 逐行精确比较，避免把 key 当 glob 误匹配。
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" && "${line}" == "${key}" ]] && return 0
  done <<< "${CLASSROOMS_HIDDEN}"
  return 1
}

# 隐藏列表增删 / 持久化（settings 数组键 hidden_classrooms）。
_classrooms_hidden_load() {
  if [[ "${CLASSROOMS_HIDDEN_LOADED}" == "1" ]]; then
    return 0
  fi
  CLASSROOMS_HIDDEN_LOADED=1
  CLASSROOMS_HIDDEN="$(settings_get_array hidden_classrooms)"
}

_classrooms_hidden_save() {
  settings_set_array hidden_classrooms "${CLASSROOMS_HIDDEN}"
}

_classrooms_hidden_add() {
  local key="$1"
  if _classrooms_is_hidden "${key}"; then
    return 0
  fi
  if [[ -n "${CLASSROOMS_HIDDEN}" ]]; then
    CLASSROOMS_HIDDEN+=$'\n'"${key}"
  else
    CLASSROOMS_HIDDEN="${key}"
  fi
}

_classrooms_hidden_remove() {
  local key="$1"
  if [[ -z "${CLASSROOMS_HIDDEN}" ]]; then
    return 0
  fi
  local out="" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" || "${line}" == "${key}" ]]; then
      continue
    fi
    if [[ -n "${out}" ]]; then
      out+=$'\n'
    fi
    out+="${line}"
  done <<< "${CLASSROOMS_HIDDEN}"
  CLASSROOMS_HIDDEN="${out}"
}

_classrooms_hidden_count() {
  if [[ -z "${CLASSROOMS_HIDDEN}" ]]; then
    printf '0'
    return 0
  fi
  local n=0 line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${line}" ]]; then
      n=$((n + 1))
    fi
  done <<< "${CLASSROOMS_HIDDEN}"
  printf '%s' "${n}"
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
      (.campuses[$i].rooms // []) as $rooms
      | $rooms[]
      | (.building // "") as $building
      | (.room // "") as $room
      | (.size // "") as $size
      | (.available_slots // []) as $slots
      | [ ($building | gsub("[\t\r\n]"; " ")),
          ($room | gsub("[\t\r\n]"; " ")),
          ($size | tostring),
          ($slots | map(tostring) | join(",")) ]
      | join("\u001f")
    ' 2>/dev/null || true)"
    # 追加第 5 列：友好时段文本（连续节次合并为 HH:MM-HH:MM，空则「满」）。
    local out="" line slots
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      slots="${line##*$'\x1f'}"
      out+="${line}"$'\x1f'"$(_classrooms_slot_text "${slots}")"$'\n'
    done <<< "${rows}"
    rows="${out}"
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

# 当前校区 + 楼/楼层/时段/隐藏筛选后的房间行（纯 bash 过滤），
# 输出到 _CLASSROOMS_ROWS 并设置 _CLASSROOMS_COUNT。
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
  local i building room slots rest row
  for ((i = 0; i < ${#all[@]}; i++)); do
    row="${all[$i]}"
    [[ -z "${row}" ]] && continue
    # 参数展开切分 TSV 字段，避免每条一次 herestring（fork）。
    building="${row%%$'\x1f'*}"
    rest="${row#*$'\x1f'}"
    room="${rest%%$'\x1f'*}"
    rest="${rest#*$'\x1f'}"   # 跳过 size
    rest="${rest#*$'\x1f'}"   # 指向 slots
    slots="${rest%%$'\x1f'*}"
    # 楼筛选。
    if [[ -n "${CLASSROOMS_BUILDING}" && "${building}" != "${CLASSROOMS_BUILDING}" ]]; then
      continue
    fi
    # 楼层筛选。
    if [[ -n "${CLASSROOMS_FLOOR}" && "$(_classrooms_floor_of "${room}")" != "${CLASSROOMS_FLOOR}" ]]; then
      continue
    fi
    # 时段筛选。
    if [[ -n "${CLASSROOMS_SLOT}" ]]; then
      _classrooms_has_slot "${slots}" "${CLASSROOMS_SLOT}" || continue
    fi
    # 隐藏筛选（显示隐藏模式时跳过，便于取消隐藏）。
    if [[ "${CLASSROOMS_SHOW_HIDDEN}" != "1" ]] && _classrooms_is_hidden "${building}|${room}"; then
      continue
    fi
    _CLASSROOMS_ROWS+=("${row}")
  done
  _CLASSROOMS_COUNT="${#_CLASSROOMS_ROWS[@]}"
}

# 当前楼（或当前校区）实际存在的楼层（每行一个，升序去重）。
_classrooms_floors() {
  local src
  if (( CLASSROOMS_CAMPUS == 0 )); then
    src="${CLASSROOMS_CAMPUS0_ROWS}"
  else
    src="${CLASSROOMS_CAMPUS1_ROWS}"
  fi
  if [[ -z "${src}" ]]; then
    return 0
  fi
  local list="" building room fl rest
  local -a all=()
  readarray -t all <<< "${src}"
  local line
  for line in "${all[@]}"; do
    [[ -z "${line}" ]] && continue
    building="${line%%$'\x1f'*}"
    if [[ -z "${CLASSROOMS_BUILDING}" || "${building}" == "${CLASSROOMS_BUILDING}" ]]; then
      rest="${line#*$'\x1f'}"
      room="${rest%%$'\x1f'*}"
      fl="$(_classrooms_floor_of "${room}")"
      if [[ -n "${fl}" ]]; then
        list+="${fl}"$'\n'
      fi
    fi
  done
  if [[ -n "${list}" ]]; then
    printf '%s' "${list}" | sort -n -u
  fi
  return 0
}

# 当前选中房间的隐藏键 building|room（无选中则空）。
_classrooms_selected_key() {
  _classrooms_filtered
  local row="${_CLASSROOMS_ROWS[$CLASSROOMS_SEL]:-}"
  if [[ -z "${row}" ]]; then
    printf ''
    return 0
  fi
  local building="${row%%$'\x1f'*}"
  local rest="${row#*$'\x1f'}"
  local room="${rest%%$'\x1f'*}"
  printf '%s|%s' "${building}" "${room}"
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
    CLASSROOMS_SLOT=""
    CLASSROOMS_FLOOR=""
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
    CLASSROOMS_SLOT=""
    CLASSROOMS_FLOOR=""
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
  local building room size slots slot_text rest
  building="${row%%$'\x1f'*}"
  rest="${row#*$'\x1f'}"
  room="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  size="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  slots="${rest%%$'\x1f'*}"
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
  # 显示隐藏模式下，给已隐藏房间加标记，便于识别后取消隐藏。
  if [[ "${CLASSROOMS_SHOW_HIDDEN}" == "1" ]] && _classrooms_is_hidden "${building}|${room}"; then
    line="[已隐藏] ${line}"
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
  # 逐项拼接，超出宽度就停（保留「全部」），避免窄终端横向换行。
  local maxw=$((UI_COLS - 2))
  local line="" plain="" is_cur item
  is_cur=0
  [[ -z "${CLASSROOMS_BUILDING}" ]] && is_cur=1
  if (( is_cur )); then
    line+="$(ui_paint hl '全部')"
  else
    line+="$(ui_paint text '全部')"
  fi
  plain="全部"
  for b in "${buildings[@]}"; do
    item="  ${b}"
    _core_width "${plain}${item}"
    if (( _CORE_W > maxw )); then
      break
    fi
    plain+="${item}"
    if [[ "${b}" == "${CLASSROOMS_BUILDING}" ]]; then
      line+="$(ui_paint hl "${item}")"
    else
      line+="$(ui_paint muted "${item}")"
    fi
  done
  printf ' %s\n' "${line}"
}

# 时段筛选条（「全部」+ 14 个节次开始时间，分两行显示避免窄终端横向越界）。
_classrooms_render_slot_bar() {
  printf ' %s\n' "$(ui_paint title '时段筛选')"
  _classrooms_slot_bar_line 0 6 1
  _classrooms_slot_bar_line 7 13 0
}

# 渲染 [from,to] 区间的时段标签行；first 为 1 时在行首加「全部」。
_classrooms_slot_bar_line() {
  local from="$1" to="$2" first="$3"
  local line="" i label
  if [[ "${first}" == "1" ]]; then
    if [[ -z "${CLASSROOMS_SLOT}" ]]; then
      line+="$(ui_paint hl '全部')"
    else
      line+="$(ui_paint text '全部')"
    fi
  fi
  for ((i = from; i <= to; i++)); do
    label="$(_classrooms_slot_start "${i}")"
    if [[ "${CLASSROOMS_SLOT}" == "${i}" ]]; then
      line+="  $(ui_paint hl "${label}")"
    else
      line+="  $(ui_paint muted "${label}")"
    fi
  done
  printf ' %s\n' "${line}"
}

# 楼层筛选条（「全部」+ 当前楼实际存在的楼层，当前项高亮）。
_classrooms_render_floor_bar() {
  printf ' %s\n' "$(ui_paint title '楼层筛选')"
  local -a floors=()
  local f
  while IFS= read -r f; do [[ -n "${f}" ]] && floors+=("${f}"); done < <(_classrooms_floors)
  local line=""
  if [[ -z "${CLASSROOMS_FLOOR}" ]]; then
    line+="$(ui_paint hl '全部')"
  else
    line+="$(ui_paint text '全部')"
  fi
  for f in "${floors[@]}"; do
    if [[ "${f}" == "${CLASSROOMS_FLOOR}" ]]; then
      line+="  $(ui_paint hl "${f} 楼")"
    else
      line+="  $(ui_paint muted "${f} 楼")"
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

  # 顶部固定行：页眉+分隔(2) + 空行+标题+信息行+键位行+空行(5) + 楼筛选(2) + 时段筛选(3，分两行) + 楼层筛选(2) + 底部三行(3) = 17。
  local visible=$((UI_ROWS - 17))
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

  local target_date campus_name building_disp slot_disp floor_disp total hidden_count
  target_date="$(printf '%s' "${CLASSROOMS_DATA}" | jq -r '.target_date // ""' 2>/dev/null || true)"
  campus_name="$(printf '%s' "${CLASSROOMS_DATA}" | jq -r --argjson i "${CLASSROOMS_CAMPUS}" '.campuses[$i].campus_name // ""' 2>/dev/null || true)"
  building_disp="${CLASSROOMS_BUILDING:-全部}"
  slot_disp="全部"
  if [[ -n "${CLASSROOMS_SLOT}" ]]; then
    slot_disp="$(_classrooms_slot_label "${CLASSROOMS_SLOT}")"
  fi
  floor_disp="全部"
  if [[ -n "${CLASSROOMS_FLOOR}" ]]; then
    floor_disp="${CLASSROOMS_FLOOR} 楼"
  fi
  hidden_count="$(_classrooms_hidden_count)"
  _classrooms_filtered
  total="${_CLASSROOMS_COUNT}"

  printf ' %s\n' "$(ui_paint muted "$(core_fit "空教室 · ${target_date} · 校区 ${campus_name} · 楼 ${building_disp} · 时段 ${slot_disp} · 楼层 ${floor_disp} · 共 ${total} 间 · 隐藏 ${hidden_count} 间" "$((UI_COLS - 2))")")"
  printf ' %s\n' "$(ui_paint muted "$(core_fit "t 时段 · F 楼层 · h 隐藏 · H 显示隐藏 · ←→ 校区 · f 楼 · ↑↓ 选择 · r 刷新" "$((UI_COLS - 2))")")"
  printf '\n'
  _classrooms_render_building_bar
  _classrooms_render_slot_bar
  _classrooms_render_floor_bar
  _classrooms_render_list
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染列表或错误。
render_classrooms() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  _classrooms_hidden_load
  if _classrooms_stale; then
    if [[ -z "${TUI_FETCH_PID}" ]]; then
      if [[ "${CLASSROOMS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
        CLASSROOMS_DATA=""; CLASSROOMS_CAMPUS0_ROWS=""; CLASSROOMS_CAMPUS1_ROWS=""
        CLASSROOMS_CAMPUS0_BUILDINGS=""; CLASSROOMS_CAMPUS1_BUILDINGS=""
        CLASSROOMS_CAMPUS=0; CLASSROOMS_BUILDING=""; CLASSROOMS_SLOT=""; CLASSROOMS_FLOOR=""
        CLASSROOMS_SEL=0; CLASSROOMS_OFFSET=0
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
    CLASSROOMS_SLOT=""
    CLASSROOMS_FLOOR=""
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

# 按键处理：←/→ 切校区、f 循环楼筛选、F 循环楼层、t 循环时段、h 隐藏/显示、
# ↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_classrooms_key() {
  local key="$1"
  local total
  case "${key}" in
    LEFT|RIGHT)
      CLASSROOMS_CAMPUS=$(( 1 - CLASSROOMS_CAMPUS ))
      CLASSROOMS_BUILDING=""
      CLASSROOMS_FLOOR=""
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
      CLASSROOMS_FLOOR=""
      CLASSROOMS_SEL=0
      CLASSROOMS_OFFSET=0
      ;;
    t)
      # 全部 → 第 1 节 → … → 第 14 节 → 全部，循环。
      if [[ -z "${CLASSROOMS_SLOT}" ]]; then
        CLASSROOMS_SLOT=0
      elif (( CLASSROOMS_SLOT + 1 < ${#SLOT_TIMES[@]} )); then
        CLASSROOMS_SLOT=$((CLASSROOMS_SLOT + 1))
      else
        CLASSROOMS_SLOT=""
      fi
      CLASSROOMS_SEL=0
      CLASSROOMS_OFFSET=0
      ;;
    F)
      # 全部 → 当前楼各楼层 → 全部，循环（仅当前楼实际存在的楼层）。
      local -a floors=()
      local f fidx=-1 fi=0
      while IFS= read -r f; do [[ -n "${f}" ]] && floors+=("${f}"); done < <(_classrooms_floors)
      if [[ ${#floors[@]} -gt 0 ]]; then
        if [[ -z "${CLASSROOMS_FLOOR}" ]]; then
          CLASSROOMS_FLOOR="${floors[0]}"
        else
          for f in "${floors[@]}"; do
            if [[ "${f}" == "${CLASSROOMS_FLOOR}" ]]; then fidx=$fi; break; fi
            fi=$((fi + 1))
          done
          if (( fidx >= 0 && fidx + 1 < ${#floors[@]} )); then
            CLASSROOMS_FLOOR="${floors[$((fidx + 1))]}"
          else
            CLASSROOMS_FLOOR=""
          fi
        fi
      fi
      CLASSROOMS_SEL=0
      CLASSROOMS_OFFSET=0
      ;;
    h)
      # 隐藏/显示当前选中房间（持久化到 settings）。
      local hkey
      hkey="$(_classrooms_selected_key)"
      if [[ -n "${hkey}" ]]; then
        if _classrooms_is_hidden "${hkey}"; then
          _classrooms_hidden_remove "${hkey}"
        else
          _classrooms_hidden_add "${hkey}"
        fi
        _classrooms_hidden_save
        # 隐藏后列表变短，选中下标交给下一帧 _classrooms_render_list 钳位。
      fi
      ;;
    H)
      # 切换「显示已隐藏」模式，便于对已隐藏房间取消隐藏。
      CLASSROOMS_SHOW_HIDDEN=$(( 1 - CLASSROOMS_SHOW_HIDDEN ))
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
