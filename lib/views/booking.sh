#!/usr/bin/env bash
# views/booking.sh —— 研讨间预约视图：分类 → 房间 → 空闲时段 → 预约/登记抢约；我的预约；待抢约。

set -euo pipefail

# 视图状态。
BOOKING_LOADED=0         # 分类是否已加载尝试过（含失败）。
BOOKING_ACCOUNT=""       # 分类数据所属账号。
BOOKING_CATEGORIES=""    # 分类 JSON [{id,name}]。
BOOKING_SEL_CAT=0
BOOKING_CATS_LOADED=0    # 分类是否已尝试加载（含失败）。
BOOKING_ROOMS_DATA=""    # 选中分类的房间 JSON {labId,today,tomorrow,rooms:[...]}。
BOOKING_SEL_ROOM=0
BOOKING_DATE_OFF=0       # 0=今天，1=明天。
BOOKING_SLOTS=""         # 当前房间 + 日期的空闲时段 JSON [{start,end}]。
BOOKING_SEL_SLOT=0
BOOKING_OWN=""           # 我的预约 JSON [{uuid,devName,begin,end,status_label}]。
BOOKING_OWN_LOADED=0
BOOKING_OWN_SEL=0
BOOKING_PENDING=""       # 待抢约（内存缓存，换行分隔的 JSON 对象）。
BOOKING_PENDING_LOADED=0
BOOKING_PENDING_SEL=0
BOOKING_TAB=0            # 0=浏览，1=我的预约，2=待抢约。
BOOKING_DEPTH=0          # 浏览内：0=分类，1=房间，2=房间详情。
BOOKING_FETCH_KIND=""    # 在途拉取类型：categories/rooms/own。
BOOKING_SEL_CAT_ID=""    # 当前选中分类 id。
BOOKING_ROOM_ROWS=""     # 房间列表预计算（TSV：devId、name、minUser、maxUser、count_today、count_tomorrow）。

# 表单收集结果（预约 / 登记抢约共用）。
BOOKING_FORM_BEGIN=""
BOOKING_FORM_END=""
BOOKING_FORM_TESTNAME=""
BOOKING_FORM_MEMBERS=""
BOOKING_FORM_KIND=""

# 是否需要重新加载分类（账号切换）。
_booking_stale() {
  [[ "${BOOKING_LOADED}" != "1" || "${BOOKING_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# ---------------------------------------------------------------------------
# 拉取与回调
# ---------------------------------------------------------------------------

_booking_start_fetch() {
  local kind="$1"
  shift
  _async_stop
  BOOKING_FETCH_KIND="${kind}"
  case "${kind}" in
    categories) _async_start booking booking_fetch_categories ;;
    rooms) _async_start booking booking_fetch_rooms_combined "$@" ;;
    own) _async_start booking booking_fetch_own ;;
  esac
}

apply_booking() {
  local file="$1" data
  data="$(cat "${file}" 2>/dev/null || true)"
  case "${BOOKING_FETCH_KIND}" in
    categories)
      BOOKING_CATS_LOADED=1
      if [[ "${data}" == ERROR:* ]]; then
        core_err "${data#ERROR:}"
        BOOKING_LOADED=1
        BOOKING_ACCOUNT="${BUPTY_ACCOUNT}"
      elif [[ -n "${data}" ]]; then
        BOOKING_CATEGORIES="${data}"
        BOOKING_ACCOUNT="${BUPTY_ACCOUNT}"
        BOOKING_LOADED=1
        BOOKING_SEL_CAT=0
        core_clear_err
      else
        core_err "分类加载失败。"
        BOOKING_LOADED=1
        BOOKING_ACCOUNT="${BUPTY_ACCOUNT}"
      fi
      ;;
    rooms)
      if [[ "${data}" == ERROR:* ]]; then
        core_err "${data#ERROR:}"
        BOOKING_ROOMS_DATA=""
      elif [[ -n "${data}" ]]; then
        BOOKING_ROOMS_DATA="${data}"
        BOOKING_SEL_ROOM=0
        BOOKING_DATE_OFF=0
        BOOKING_DEPTH=1
        _booking_precompute_room_rows
        _booking_precompute_slots
        core_clear_err
      else
        core_err "房间加载失败。"
        BOOKING_ROOMS_DATA=""
      fi
      ;;
    own)
      BOOKING_OWN_LOADED=1
      if [[ "${data}" == ERROR:* ]]; then
        core_err "${data#ERROR:}"
        BOOKING_OWN=""
      elif [[ -n "${data}" ]]; then
        BOOKING_OWN="${data}"
        BOOKING_OWN_SEL=0
        core_clear_err
      else
        core_err "我的预约加载失败。"
        BOOKING_OWN=""
      fi
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 预计算
# ---------------------------------------------------------------------------

_booking_selected_room() {
  printf '%s' "${BOOKING_ROOMS_DATA}" | jq -c '.rooms['"${BOOKING_SEL_ROOM}"'] // null' 2>/dev/null || true
}

_booking_selected_date() {
  if (( BOOKING_DATE_OFF == 0 )); then
    printf '%s' "${BOOKING_ROOMS_DATA}" | jq -r '.today // empty' 2>/dev/null || true
  else
    printf '%s' "${BOOKING_ROOMS_DATA}" | jq -r '.tomorrow // empty' 2>/dev/null || true
  fi
}

_booking_precompute_room_rows() {
  BOOKING_ROOM_ROWS=""
  [[ -z "${BOOKING_ROOMS_DATA}" ]] && return 0
  BOOKING_ROOM_ROWS="$(printf '%s' "${BOOKING_ROOMS_DATA}" | jq -r '
    .rooms[]?
    | [ (.devId | tostring),
        ((.devName // .roomName // "") | gsub("[\t\r\n]"; " ")),
        ((.minUser // 1) | tostring),
        ((.maxUser // 1) | tostring),
        ((.count_today // 0) | tostring),
        ((.count_tomorrow // 0) | tostring) ]
    | join("\u001f")' 2>/dev/null || true)"
}

_booking_rooms_count() {
  local n
  n="$(printf '%s' "${BOOKING_ROOMS_DATA}" | jq -r 'if (.rooms | type) == "array" then (.rooms | length | tostring) else "0" end' 2>/dev/null || true)"
  [[ -n "${n}" && "${n}" != "null" ]] || n=0
  printf '%s' "${n}"
}

_booking_precompute_slots() {
  BOOKING_SLOTS=""
  BOOKING_SEL_SLOT=0
  local room
  room="$(_booking_selected_room)"
  [[ -z "${room}" || "${room}" == "null" ]] && return 0
  if (( BOOKING_DATE_OFF == 0 )); then
    BOOKING_SLOTS="$(printf '%s' "${room}" | jq -c '.free // []' 2>/dev/null || true)"
  else
    BOOKING_SLOTS="$(printf '%s' "${room}" | jq -c '.free_tomorrow // []' 2>/dev/null || true)"
  fi
}

_booking_slots_count() {
  local n
  n="$(printf '%s' "${BOOKING_SLOTS}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  [[ -n "${n}" && "${n}" != "null" ]] || n=0
  printf '%s' "${n}"
}

_booking_categories_count() {
  local n
  n="$(printf '%s' "${BOOKING_CATEGORIES}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  [[ -n "${n}" && "${n}" != "null" ]] || n=0
  printf '%s' "${n}"
}

_booking_own_count() {
  local n
  n="$(printf '%s' "${BOOKING_OWN}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  [[ -n "${n}" && "${n}" != "null" ]] || n=0
  printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# 待抢约缓存
# ---------------------------------------------------------------------------

_booking_pending_load() {
  BOOKING_PENDING_LOADED=1
  BOOKING_PENDING="$(booking_pending_list)"
}

_booking_pending_count() {
  if [[ -z "${BOOKING_PENDING}" ]]; then printf '0'; return 0; fi
  local n=0 line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && n=$(( n + 1 ))
  done <<< "${BOOKING_PENDING}"
  printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# 渲染：分类列表
# ---------------------------------------------------------------------------

_booking_render_category_row() {
  local i="$1"
  local row
  row="$(printf '%s' "${BOOKING_CATEGORIES}" | jq -r '.['"${i}"'] | (.id | tostring) + "\u001f" + (.name // "")' 2>/dev/null || true)"
  [[ -z "${row}" ]] && return 0
  local name="${row#*$'\x1f'}"
  if (( i == BOOKING_SEL_CAT )); then
    _core_fit_compute "${name}" "$((UI_COLS - 3))"
    printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  else
    _core_fit_compute "${name}" "$((UI_COLS - 3))"
    printf '   %s\n' "${_CORE_FIT_OUT}"
  fi
}

# 分类列表。body = 正文可用行数；本页固定 5 行（正文空行 + 切页条 + 标题「研讨间」+
# 提示行 + 空行），F=5 是实测值（列表只放 1 条、UI_ROWS=1000 时正文 6 行）。
_booking_render_categories() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    body=$(( ${UI_ROWS:-24} - ${BANNER_CHROME_ROWS:-5} ))
  fi
  (( body < 0 )) && body=0
  if [[ -z "${BOOKING_CATEGORIES}" ]]; then
    if [[ -n "${TUI_FETCH_PID}" && "${BOOKING_FETCH_KIND}" == "categories" ]]; then
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  正在加载分类…' "$((UI_COLS - 1))")")"
    elif [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger "$(core_clip '  分类加载失败，请查看底部错误信息。' "$((UI_COLS - 1))")")"
    else
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无分类数据 · 按 r 刷新' "$((UI_COLS - 1))")")"
    fi
    return 0
  fi
  printf ' %s\n' "$(ui_paint muted "$(core_fit '选择分类（Enter 进入 · ←→ 切页 · r 刷新）' "$((UI_COLS - 2))")")"
  printf '\n'
  local total i
  total="$(_booking_categories_count)"
  (( BOOKING_SEL_CAT >= total )) && BOOKING_SEL_CAT=$(( total - 1 ))
  (( BOOKING_SEL_CAT < 0 )) && BOOKING_SEL_CAT=0
  local visible=$(( body - 5 ))
  if (( visible < 1 )); then visible=1; fi
  local end=$total
  if (( end > visible )); then end=$visible; fi
  local offset=0
  if (( BOOKING_SEL_CAT >= end )); then offset=$(( BOOKING_SEL_CAT - end + 1 )); end=$(( BOOKING_SEL_CAT + 1 )); fi
  for ((i = offset; i < end; i++)); do
    _booking_render_category_row "${i}"
  done
}

# ---------------------------------------------------------------------------
# 渲染：房间列表
# ---------------------------------------------------------------------------

_booking_render_room_row() {
  local i="$1" row="$2"
  [[ -z "${row}" ]] && return 0
  local devid name minu maxu ct cm rest
  devid="${row%%$'\x1f'*}"
  rest="${row#*$'\x1f'}"
  name="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  minu="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  maxu="${rest%%$'\x1f'*}"
  rest="${rest#*$'\x1f'}"
  ct="${rest%%$'\x1f'*}"
  cm="${rest#*$'\x1f'}"
  local line="${name} · 最少${minu}人/最多${maxu}人 · 今天${ct}段 明天${cm}段"
  if (( i == BOOKING_SEL_ROOM )); then
    _core_fit_compute "${line}" "$((UI_COLS - 3))"
    printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  else
    _core_fit_compute "${line}" "$((UI_COLS - 3))"
    printf '   %s\n' "${_CORE_FIT_OUT}"
  fi
}

# 房间列表。body = 正文可用行数；本页固定 5 行（同分类页：正文空行 + 切页条 +
# 标题 + 信息行 + 空行），F=5（实测同上）。
_booking_render_rooms() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    body=$(( ${UI_ROWS:-24} - ${BANNER_CHROME_ROWS:-5} ))
  fi
  (( body < 0 )) && body=0
  if [[ -z "${BOOKING_ROOMS_DATA}" ]]; then
    if [[ -n "${TUI_FETCH_PID}" && "${BOOKING_FETCH_KIND}" == "rooms" ]]; then
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  正在加载房间…' "$((UI_COLS - 1))")")"
    elif [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger "$(core_clip '  房间加载失败，请查看底部错误信息。' "$((UI_COLS - 1))")")"
    else
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无房间数据。' "$((UI_COLS - 1))")")"
    fi
    return 0
  fi
  local lab
  lab="$(printf '%s' "${BOOKING_ROOMS_DATA}" | jq -r '.labId // empty' 2>/dev/null || true)"
  printf ' %s\n' "$(ui_paint muted "$(core_fit "房间列表（分类 ${lab} · Enter 选房间 · ← 返回 · r 刷新）" "$((UI_COLS - 2))")")"
  printf '\n'
  local total i
  total="$(_booking_rooms_count)"
  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted "$(core_clip '  该分类暂无房间。' "$((UI_COLS - 1))")")"
    return 0
  fi
  (( BOOKING_SEL_ROOM >= total )) && BOOKING_SEL_ROOM=$(( total - 1 ))
  (( BOOKING_SEL_ROOM < 0 )) && BOOKING_SEL_ROOM=0
  local visible=$(( body - 5 ))
  if (( visible < 1 )); then visible=1; fi
  local end=$total
  if (( end > visible )); then end=$visible; fi
  local offset=0
  if (( BOOKING_SEL_ROOM >= end )); then offset=$(( BOOKING_SEL_ROOM - end + 1 )); end=$(( BOOKING_SEL_ROOM + 1 )); fi
  local -a rows=()
  readarray -t rows <<< "${BOOKING_ROOM_ROWS}"
  for ((i = offset; i < end; i++)); do
    _booking_render_room_row "${i}" "${rows[$i]:-}"
  done
}

# ---------------------------------------------------------------------------
# 渲染：房间详情（空闲时段 + 操作）
# ---------------------------------------------------------------------------

_booking_render_slot_row() {
  local i="$1"
  local slot
  slot="$(printf '%s' "${BOOKING_SLOTS}" | jq -c '.['"${i}"'] // null' 2>/dev/null || true)"
  [[ -z "${slot}" || "${slot}" == "null" ]] && return 0
  local start end line
  start="$(printf '%s' "${slot}" | jq -r '.start // ""' 2>/dev/null || true)"
  end="$(printf '%s' "${slot}" | jq -r '.end // ""' 2>/dev/null || true)"
  line="${start}-${end}"
  if (( i == BOOKING_SEL_SLOT )); then
    _core_fit_compute "${line}" "$((UI_COLS - 3))"
    printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  else
    _core_fit_compute "${line}" "$((UI_COLS - 3))"
    printf '   %s\n' "${_CORE_FIT_OUT}"
  fi
}

# 房间详情（空闲时段 + 操作）。body = 正文可用行数；本页固定 6 行（正文空行 + 切页条 +
# 标题 + 键位提示 + 空行…共 6），F=6（实测：列表只放 1 条、UI_ROWS=1000 时正文 7 行）。
_booking_render_room() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    body=$(( ${UI_ROWS:-24} - ${BANNER_CHROME_ROWS:-5} ))
  fi
  (( body < 0 )) && body=0
  local room
  room="$(_booking_selected_room)"
  if [[ -z "${room}" || "${room}" == "null" ]]; then
    printf ' %s\n' "$(ui_paint muted "$(core_clip '  请先选择房间。' "$((UI_COLS - 1))")")"
    return 0
  fi
  local devname minu maxu date
  devname="$(printf '%s' "${room}" | jq -r '.devName // .roomName // ""' 2>/dev/null || true)"
  minu="$(printf '%s' "${room}" | jq -r '.minUser // 1' 2>/dev/null || true)"
  maxu="$(printf '%s' "${room}" | jq -r '.maxUser // 1' 2>/dev/null || true)"
  date="$(_booking_selected_date)"
  local dlabel
  if (( BOOKING_DATE_OFF == 0 )); then dlabel="今天"; else dlabel="明天"; fi
  printf ' %s\n' "$(ui_paint title "$(core_fit "${devname} · 最少${minu}人/最多${maxu}人 · ${dlabel} ${date}" "$((UI_COLS - 2))")")"
  printf ' %s\n' "$(ui_paint muted "$(core_fit 'Enter 预约 · a 登记自动抢约 · d 切今/明 · ← 返回 · r 刷新' "$((UI_COLS - 2))")")"
  printf '\n'
  local total i
  total="$(_booking_slots_count)"
  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted "$(core_clip '  该日期暂无空闲时段。' "$((UI_COLS - 1))")")"
    return 0
  fi
  (( BOOKING_SEL_SLOT >= total )) && BOOKING_SEL_SLOT=$(( total - 1 ))
  (( BOOKING_SEL_SLOT < 0 )) && BOOKING_SEL_SLOT=0
  local visible=$(( body - 6 ))
  if (( visible < 1 )); then visible=1; fi
  local end=$total
  if (( end > visible )); then end=$visible; fi
  local offset=0
  if (( BOOKING_SEL_SLOT >= end )); then offset=$(( BOOKING_SEL_SLOT - end + 1 )); end=$(( BOOKING_SEL_SLOT + 1 )); fi
  for ((i = offset; i < end; i++)); do
    _booking_render_slot_row "${i}"
  done
}

# 浏览子页分发。body = 正文可用行数（render_booking 传下来；tests/snapshot.sh 直接调用
# 本函数，故缺省时按唯一口径自行推导）。
_booking_render_browse() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    body=$(( ${UI_ROWS:-24} - ${BANNER_CHROME_ROWS:-5} ))
  fi
  (( body < 0 )) && body=0
  printf ' %s\n' "$(ui_paint title "$(core_clip '研讨间' "$((UI_COLS - 1))")")"
  if (( BOOKING_DEPTH == 0 )); then
    _booking_render_categories "${body}"
  elif (( BOOKING_DEPTH == 1 )); then
    _booking_render_rooms "${body}"
  else
    _booking_render_room "${body}"
  fi
}

# ---------------------------------------------------------------------------
# 渲染：我的预约 / 待抢约
# ---------------------------------------------------------------------------

# 我的预约。body = 正文可用行数；本页固定 5 行（正文空行 + 切页条 + 标题 + 提示行 + 空行）。
_booking_render_own() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    body=$(( ${UI_ROWS:-24} - ${BANNER_CHROME_ROWS:-5} ))
  fi
  (( body < 0 )) && body=0
  printf ' %s\n' "$(ui_paint title "$(core_clip '我的预约' "$((UI_COLS - 1))")")"
  if [[ -z "${BOOKING_OWN}" && -z "${TUI_FETCH_PID}" && "${BOOKING_OWN_LOADED}" != "1" ]]; then
    _booking_start_fetch own
  fi
  if [[ -z "${BOOKING_OWN}" ]]; then
    if [[ -n "${TUI_FETCH_PID}" && "${BOOKING_FETCH_KIND}" == "own" ]]; then
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  正在加载我的预约…' "$((UI_COLS - 1))")")"
    elif [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger "$(core_clip '  我的预约加载失败，请查看底部错误信息。' "$((UI_COLS - 1))")")"
    else
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无预约 · Enter 取消 · r 刷新' "$((UI_COLS - 1))")")"
    fi
    return 0
  fi
  printf ' %s\n' "$(ui_paint muted "$(core_fit 'Enter 取消选中预约 · r 刷新' "$((UI_COLS - 2))")")"
  printf '\n'
  local total i
  total="$(_booking_own_count)"
  (( BOOKING_OWN_SEL >= total )) && BOOKING_OWN_SEL=$(( total - 1 ))
  (( BOOKING_OWN_SEL < 0 )) && BOOKING_OWN_SEL=0
  local visible=$(( body - 5 ))
  if (( visible < 1 )); then visible=1; fi
  local end=$total
  if (( end > visible )); then end=$visible; fi
  local offset=0
  if (( BOOKING_OWN_SEL >= end )); then offset=$(( BOOKING_OWN_SEL - end + 1 )); end=$(( BOOKING_OWN_SEL + 1 )); fi
  local row devname begin end label line
  for ((i = offset; i < end; i++)); do
    row="$(printf '%s' "${BOOKING_OWN}" | jq -c '.['"${i}"'] // null' 2>/dev/null || true)"
    [[ -z "${row}" || "${row}" == "null" ]] && continue
    devname="$(printf '%s' "${row}" | jq -r '.devName // ""' 2>/dev/null || true)"
    begin="$(printf '%s' "${row}" | jq -r '.begin // ""' 2>/dev/null || true)"
    end="$(printf '%s' "${row}" | jq -r '.end // ""' 2>/dev/null || true)"
    label="$(printf '%s' "${row}" | jq -r '.status_label // ""' 2>/dev/null || true)"
    line="${devname} · ${begin} ~ ${end} · ${label}"
    if (( i == BOOKING_OWN_SEL )); then
      _core_fit_compute "${line}" "$((UI_COLS - 3))"
      printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
    else
      _core_fit_compute "${line}" "$((UI_COLS - 3))"
      printf '   %s\n' "${_CORE_FIT_OUT}"
    fi
  done
}

# 待抢约。body = 正文可用行数；本页固定 5 行（正文空行 + 切页条 + 标题 + 信息行 + 空行）。
_booking_render_pending() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    body=$(( ${UI_ROWS:-24} - ${BANNER_CHROME_ROWS:-5} ))
  fi
  (( body < 0 )) && body=0
  printf ' %s\n' "$(ui_paint title "$(core_clip '待抢约' "$((UI_COLS - 1))")")"
  if [[ "${BOOKING_PENDING_LOADED}" != "1" ]]; then
    _booking_pending_load
  fi
  local enabled
  if [[ "$(settings_get auto_book_enabled)" == "true" ]]; then enabled="开"; else enabled="关"; fi
  printf ' %s\n' "$(ui_paint muted "$(core_fit "自动抢约：${enabled}（a 切换）· Enter 删除 · r 刷新" "$((UI_COLS - 2))")")"
  printf '\n'
  local total
  total="$(_booking_pending_count)"
  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无待抢约。在房间详情选中时段后按 a 登记。' "$((UI_COLS - 1))")")"
    return 0
  fi
  (( BOOKING_PENDING_SEL >= total )) && BOOKING_PENDING_SEL=$(( total - 1 ))
  (( BOOKING_PENDING_SEL < 0 )) && BOOKING_PENDING_SEL=0
  local -a rows=()
  readarray -t rows <<< "${BOOKING_PENDING}"
  local visible=$(( body - 5 ))
  if (( visible < 1 )); then visible=1; fi
  local end=$total
  if (( end > visible )); then end=$visible; fi
  local offset=0
  if (( BOOKING_PENDING_SEL >= end )); then offset=$(( BOOKING_PENDING_SEL - end + 1 )); end=$(( BOOKING_PENDING_SEL + 1 )); fi
  local i item begin end dev line
  for ((i = offset; i < end; i++)); do
    item="${rows[$i]:-}"
    [[ -z "${item}" ]] && continue
    begin="$(printf '%s' "${item}" | jq -r '.begin // ""' 2>/dev/null || true)"
    end="$(printf '%s' "${item}" | jq -r '.end // ""' 2>/dev/null || true)"
    dev="$(printf '%s' "${item}" | jq -r '.devName // .devId // ""' 2>/dev/null || true)"
    line="${begin} ~ ${end} · ${dev}"
    if (( i == BOOKING_PENDING_SEL )); then
      _core_fit_compute "${line}" "$((UI_COLS - 3))"
      printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
    else
      _core_fit_compute "${line}" "$((UI_COLS - 3))"
      printf '   %s\n' "${_CORE_FIT_OUT}"
    fi
  done
}

# ---------------------------------------------------------------------------
# 视图入口
# ---------------------------------------------------------------------------

# 子页切换条（浏览 / 我的预约 / 待抢约，←→ 切页）。
# 宽度护栏：整行显示宽度必须 ≤ UI_COLS（docs/ARCHITECTURE.md 硬不变量）。
#   行首固定 1 列空格；三个页签逐项按显示宽度拼接，放不下就停——窄终端下宁可
#   少显示靠后的页签（同 _classrooms_render_building_bar 的取舍），也绝不横向
#   顶破右边界。末尾提示「←→ 切子页」按剩余宽度 core_clip 截断（不劈宽字符），
#   剩余不足 3 列（连「←→」都摆不下）时整段丢弃。宽度一律走 _core_width，
#   绝不用 ${#s}——中文与 ←→ 都是宽/歧义字符，字节数不等于列数。
_booking_render_tab_bar() {
  local line="" plain="" i chip hint avail
  local -a names=("浏览" "我的预约" "待抢约")
  local limit=$((UI_COLS - 1))          # 扣掉行首那 1 列空格，余下才是本行预算
  (( limit < 0 )) && limit=0
  for i in 0 1 2; do
    chip=" ${names[$i]} "
    _core_width "${plain}${chip}"
    (( _CORE_W > limit )) && break
    plain+="${chip}"
    if (( i == BOOKING_TAB )); then
      line+="$(ui_paint hl "${chip}")"
    else
      line+="$(ui_paint muted "${chip}")"
    fi
  done
  _core_width "${plain}"
  avail=$(( limit - _CORE_W - 2 ))      # 提示前还有 2 列分隔，其余才是提示宽度
  hint=""
  if (( avail >= 3 )); then
    hint="$(core_clip '←→ 切子页' "${avail}")"
  fi
  if [[ -n "${hint}" ]]; then
    printf ' %s  %s\n' "${line}" "$(ui_paint muted "${hint}")"
  else
    printf ' %s\n' "${line}"
  fi
}

# 进入视图渲染。body = 正文可用行数，由 tui_render 传入（不再自己减常量）。
render_booking() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows booking
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      body=$(( ${UI_ROWS:-24} - 5 ))
    fi
  fi
  (( body < 0 )) && body=0
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted "$(core_clip '  请先在设置中登录。' "$((UI_COLS - 1))")")"
    return 0
  fi
  if _booking_stale; then
    BOOKING_CATEGORIES=""
    BOOKING_CATS_LOADED=0
    BOOKING_LOADED=0
    BOOKING_ACCOUNT="${BUPTY_ACCOUNT}"
  fi
  if [[ "${BOOKING_TAB}" == "0" && -z "${BOOKING_CATEGORIES}" && "${BOOKING_CATS_LOADED}" != "1" ]]; then
    if [[ -z "${TUI_FETCH_PID}" ]]; then
      _booking_start_fetch categories
    fi
  fi
  printf '\n'
  _booking_render_tab_bar
  case "${BOOKING_TAB}" in
    1) _booking_render_own "${body}" ;;
    2) _booking_render_pending "${body}" ;;
    *) _booking_render_browse "${body}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 表单：收集主题 / 成员 / 开始时间 / 时长（预约与登记抢约共用）
# ---------------------------------------------------------------------------

# 表单统一入口：清屏并显示标题与当前房间，避免与底层空闲时段列表混叠。
_booking_form_intro() {
  local room devname
  room="$(_booking_selected_room)"
  devname="$(printf '%s' "${room}" | jq -r '.devName // .roomName // ""' 2>/dev/null || true)"
  ui_clear
  # 模态表单的抬头：只用状态行（同 assignments 的提交对话框）。
  tui_render_statusline
  printf '\n'
  printf ' %s\n' "$(ui_paint title "$(core_clip '预约登记' "$((UI_COLS - 1))")")"
  if [[ -n "${devname}" ]]; then
    printf ' %s\n' "$(ui_paint muted "$(core_clip "  房间：${devname}" "$((UI_COLS - 1))")")"
  fi
  printf ' %s\n' "$(ui_paint muted "$(core_clip '  Esc 任一步可取消' "$((UI_COLS - 1))")")"
  printf '\n'
}

_booking_collect_request() {
  local dev_id="$1" min_user="$2" max_user="$3" interval="$4" minr="$5" maxr="$6" date="$7" slot_start="$8" slot_end="$9"

  # 1. 违约检查（真正拦截仍在预约接口，这里提前提示）。
  local punish punish_tmp
  punish_tmp="$(mktemp)"
  if ! booking_fetch_punish > "${punish_tmp}"; then
    rm -f "${punish_tmp}"
    return 1
  fi
  punish="$(cat "${punish_tmp}")"
  rm -f "${punish_tmp}"
  if [[ "${punish}" == "true" ]]; then
    core_err "当前账号存在违约禁用记录，暂时无法预约。"
    return 1
  fi

  # 2. 主题（默认「科研讨论」）。
  local test_name="科研讨论" themes themes_tmp
  themes_tmp="$(mktemp)"
  if booking_fetch_themes "${dev_id}" > "${themes_tmp}"; then
    themes="$(cat "${themes_tmp}")"
  else
    themes="[]"
  fi
  rm -f "${themes_tmp}"
  local themes_n
  themes_n="$(printf '%s' "${themes}" | jq -r 'if type == "array" then (length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -n "${themes_n}" && "${themes_n}" != "0" ]]; then
    local -a opts=()
    local th
    if printf '%s' "${themes}" | jq -e 'index("科研讨论") != null' >/dev/null 2>&1; then
      opts+=("科研讨论|科研讨论")
    fi
    while IFS= read -r th; do
      [[ -n "${th}" && "${th}" != "科研讨论" ]] && opts+=("${th}|${th}")
    done < <(printf '%s' "${themes}" | jq -r '.[] // empty' 2>/dev/null)
    if (( ${#opts[@]} > 0 )); then
      if ! ui_select_option "${opts[@]}"; then core_err "已取消预约。"; return 1; fi
      test_name="${UI_SELECT_RESULT}"
    fi
  fi

  # 3. 成员（accNo；多人需同行成员学号）。
  local self_acc members_csv kind
  self_acc="$(booking_session_get_acc_no)"
  if (( min_user >= 2 )); then
    kind=2
    local peer
    if ! ui_input "同行成员学号（该房间最少 ${min_user} 人）： " "" 0 16; then core_err "已取消预约。"; return 1; fi
    peer="${UI_INPUT_RESULT}"
    if core_is_blank "${peer}"; then core_err "该房间最少 ${min_user} 人，需要同行成员。"; return 1; fi
    local peer_tmp peer_acc
    peer_tmp="$(mktemp)"
    if ! booking_resolve_member "${peer}" > "${peer_tmp}"; then rm -f "${peer_tmp}"; return 1; fi
    peer_acc="$(cat "${peer_tmp}")"
    rm -f "${peer_tmp}"
    if core_is_blank "${peer_acc}"; then core_err "未解析到同行成员 accNo。"; return 1; fi
    members_csv="${self_acc},${peer_acc}"
  else
    kind=1
    members_csv="${self_acc}"
  fi

  # 4. 开始时间（文本输入 + 校验，避免列出上百个时刻）。
  local slot_start_min slot_end_min
  slot_start_min="$(_booking_hm_to_min "${slot_start}")"
  slot_end_min="$(_booking_hm_to_min "${slot_end}")"
  if ! ui_input "开始时间 HH:MM（${slot_start}~${slot_end}，步进${interval}分钟）： " "${slot_start}" 0 5; then core_err "已取消预约。"; return 1; fi
  local start_hm start_min
  start_hm="$(core_trim "${UI_INPUT_RESULT}")"
  if [[ ! "${start_hm}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    core_err "开始时间格式应为 HH:MM（如 14:30）。"
    return 1
  fi
  local sh="${BASH_REMATCH[1]}" sm="${BASH_REMATCH[2]}"
  if (( 10#${sh} > 23 || 10#${sm} > 59 )); then core_err "开始时间无效。"; return 1; fi
  start_min=$(( 10#${sh} * 60 + 10#${sm} ))
  if (( start_min < slot_start_min )); then core_err "开始时间不能早于 ${slot_start}。"; return 1; fi
  if (( start_min + minr > slot_end_min )); then core_err "开始时间过晚，放不下最短时长。"; return 1; fi
  if (( (start_min - slot_start_min) % interval != 0 )); then core_err "开始时间需按 ${interval} 分钟步进对齐。"; return 1; fi

  # 5. 时长（文本输入 + 校验）。
  local dur maxd
  maxd="${maxr}"
  if (( start_min + maxd > slot_end_min )); then maxd=$(( slot_end_min - start_min )); fi
  if ! ui_input "时长（分钟，${minr}~${maxd}，步进${interval}）： " "${minr}" 0 3; then core_err "已取消预约。"; return 1; fi
  dur="$(core_trim "${UI_INPUT_RESULT}")"
  if [[ ! "${dur}" =~ ^[0-9]+$ ]]; then core_err "时长应为整数分钟。"; return 1; fi
  if (( dur < minr || dur > maxd )); then core_err "时长应在 ${minr}~${maxd} 分钟之间。"; return 1; fi
  if (( dur % interval != 0 )); then core_err "时长需按 ${interval} 分钟步进对齐。"; return 1; fi
  local end_min
  end_min=$(( start_min + dur ))

  BOOKING_FORM_BEGIN="${date} ${start_hm}"
  BOOKING_FORM_END="${date} $(_booking_min_to_hm "${end_min}")"
  BOOKING_FORM_TESTNAME="${test_name}"
  BOOKING_FORM_MEMBERS="${members_csv}"
  BOOKING_FORM_KIND="${kind}"
  return 0
}

# 当前选中房间 + 时段的字段。
_booking_do_book() {
  local room
  room="$(_booking_selected_room)"
  [[ -z "${room}" || "${room}" == "null" ]] && { core_err "请先选择房间。"; return 1; }
  local dev_id minu maxu interval minr maxr date
  dev_id="$(printf '%s' "${room}" | jq -r '.devId // empty' 2>/dev/null || true)"
  minu="$(printf '%s' "${room}" | jq -r '.minUser // 1' 2>/dev/null || true)"
  maxu="$(printf '%s' "${room}" | jq -r '.maxUser // 1' 2>/dev/null || true)"
  interval="$(printf '%s' "${room}" | jq -r '.timeInterval // 30' 2>/dev/null || true)"
  minr="$(printf '%s' "${room}" | jq -r '.minResvTime // 10' 2>/dev/null || true)"
  maxr="$(printf '%s' "${room}" | jq -r '.maxResvTime // 120' 2>/dev/null || true)"
  date="$(_booking_selected_date)"
  local slot slot_start slot_end
  slot="$(printf '%s' "${BOOKING_SLOTS}" | jq -c '.['"${BOOKING_SEL_SLOT}"'] // null' 2>/dev/null || true)"
  [[ -z "${slot}" || "${slot}" == "null" ]] && { core_err "请先选择空闲时段。"; return 1; }
  slot_start="$(printf '%s' "${slot}" | jq -r '.start // ""' 2>/dev/null || true)"
  slot_end="$(printf '%s' "${slot}" | jq -r '.end // ""' 2>/dev/null || true)"
  _booking_form_intro
  if ! _booking_collect_request "${dev_id}" "${minu}" "${maxu}" "${interval}" "${minr}" "${maxr}" "${date}" "${slot_start}" "${slot_end}"; then
    return 1
  fi
  tui_set_status "正在提交预约…"
  tui_render
  if booking_submit "${dev_id}" "${BOOKING_FORM_BEGIN}" "${BOOKING_FORM_END}" "${BOOKING_FORM_TESTNAME}" "${BOOKING_FORM_MEMBERS}" "${BOOKING_FORM_KIND}" >/dev/null; then
    tui_set_status "预约成功。"
    BOOKING_OWN=""
    BOOKING_OWN_LOADED=0
  else
    tui_set_status "${BUPTY_ERR:-预约失败。}"
  fi
  return 0
}

_booking_do_autobook() {
  local room
  room="$(_booking_selected_room)"
  [[ -z "${room}" || "${room}" == "null" ]] && { core_err "请先选择房间。"; return 1; }
  local dev_id dev_name minu maxu interval minr maxr lab_ids
  dev_id="$(printf '%s' "${room}" | jq -r '.devId // empty' 2>/dev/null || true)"
  dev_name="$(printf '%s' "${room}" | jq -r '.devName // .roomName // ""' 2>/dev/null || true)"
  minu="$(printf '%s' "${room}" | jq -r '.minUser // 1' 2>/dev/null || true)"
  maxu="$(printf '%s' "${room}" | jq -r '.maxUser // 1' 2>/dev/null || true)"
  interval="$(printf '%s' "${room}" | jq -r '.timeInterval // 30' 2>/dev/null || true)"
  minr="$(printf '%s' "${room}" | jq -r '.minResvTime // 10' 2>/dev/null || true)"
  maxr="$(printf '%s' "${room}" | jq -r '.maxResvTime // 120' 2>/dev/null || true)"
  lab_ids="$(printf '%s' "${BOOKING_ROOMS_DATA}" | jq -r '.labId // empty' 2>/dev/null || true)"

  _booking_form_intro

  # 1. 目标日期（默认明天，可输入更晚的日期）。
  local today tomorrow target_date days
  today="$(core_today)"
  tomorrow="$(TZ=Asia/Shanghai date -d "${today} +1 day" +%Y-%m-%d 2>/dev/null || date -d "${today} +1 day" +%Y-%m-%d)"
  if ! ui_input "目标日期 YYYY-MM-DD（默认明天 ${tomorrow}，可更晚）： " "${tomorrow}" 0 10; then core_err "已取消。"; return 1; fi
  target_date="$(core_trim "${UI_INPUT_RESULT}")"
  if [[ ! "${target_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then core_err "日期格式应为 YYYY-MM-DD。"; return 1; fi
  if [[ "$(TZ=Asia/Shanghai date -d "${target_date}" +%Y-%m-%d 2>/dev/null)" != "${target_date}" ]]; then core_err "日期无效。"; return 1; fi
  days="$(core_days_between "${target_date}" "${today}")"
  if [[ ! "${days}" =~ ^[0-9]+$ ]] || (( days <= 0 )); then core_err "目标日期需为明天及以后。"; return 1; fi

  # 2. 开始时间 + 时长：以房间开放时间为范围（未来日期尚未放出空闲时段）。
  local open_start open_end
  open_start="$(printf '%s' "${room}" | jq -r '.open_start // "08:00"' 2>/dev/null || true)"
  open_end="$(printf '%s' "${room}" | jq -r '.open_end // "22:00"' 2>/dev/null || true)"
  if ! _booking_collect_request "${dev_id}" "${minu}" "${maxu}" "${interval}" "${minr}" "${maxr}" "${target_date}" "${open_start}" "${open_end}"; then
    return 1
  fi

  # 3. 立即尝试预约（明天/今天已放出的时段可当场成功）；失败则登记待抢约，后台持续尝试。
  local submit_err
  tui_set_status "正在尝试预约…"
  tui_render
  if booking_submit "${dev_id}" "${BOOKING_FORM_BEGIN}" "${BOOKING_FORM_END}" "${BOOKING_FORM_TESTNAME}" "${BOOKING_FORM_MEMBERS}" "${BOOKING_FORM_KIND}" >/dev/null; then
    tui_set_status "预约成功。"
    BOOKING_OWN=""
    BOOKING_OWN_LOADED=0
    return 0
  fi
  submit_err="${BUPTY_ERR:-未知错误}"

  local pending_item
  pending_item="$(jq -c -n --arg dev "${dev_id}" --arg dn "${dev_name}" --arg lab "${lab_ids}" \
    --arg b "${BOOKING_FORM_BEGIN}" --arg e "${BOOKING_FORM_END}" \
    --arg tn "${BOOKING_FORM_TESTNAME}" --arg mem "${BOOKING_FORM_MEMBERS}" \
    --arg kind "${BOOKING_FORM_KIND}" --arg now "$(core_now_rfc3339)" \
    '{devId:$dev, devName:$dn, labIds:$lab, begin:$b, end:$e, testName:$tn, member_accnos_csv:$mem, member_kind:$kind, created_at:$now}')"
  booking_pending_add "${pending_item}"
  BOOKING_PENDING_LOADED=0
  tui_set_status "当前无法预约（${submit_err}），已登记待抢约，后台将持续尝试。"
  return 0
}

# ---------------------------------------------------------------------------
# 按键处理
# ---------------------------------------------------------------------------

handle_booking_key() {
  local key="$1"
  local total
  case "${key}" in
    LEFT)
      if (( BOOKING_DEPTH > 0 )); then
        BOOKING_DEPTH=$(( BOOKING_DEPTH - 1 ))
        if (( BOOKING_DEPTH == 1 )); then BOOKING_SEL_ROOM=0; fi
      elif (( BOOKING_TAB > 0 )); then
        BOOKING_TAB=$(( BOOKING_TAB - 1 ))
      fi
      ;;
    RIGHT)
      if (( BOOKING_DEPTH == 0 )); then
        BOOKING_TAB=$(( (BOOKING_TAB + 1) % 3 ))
      fi
      ;;
    r)
      if (( BOOKING_TAB == 0 )); then
        if (( BOOKING_DEPTH == 0 )); then
          BOOKING_CATEGORIES=""
          BOOKING_CATS_LOADED=0
          _booking_start_fetch categories
        elif (( BOOKING_DEPTH == 1 )); then
          BOOKING_ROOMS_DATA=""
          _booking_start_fetch rooms "${BOOKING_SEL_CAT_ID}"
        else
          BOOKING_ROOMS_DATA=""
          _booking_start_fetch rooms "${BOOKING_SEL_CAT_ID}"
        fi
      elif (( BOOKING_TAB == 1 )); then
        BOOKING_OWN=""
        BOOKING_OWN_LOADED=0
        _booking_start_fetch own
      else
        BOOKING_PENDING_LOADED=0
        _booking_pending_load
      fi
      ;;
    UP)
      if (( BOOKING_TAB == 0 )); then
        if (( BOOKING_DEPTH == 0 )); then
          if (( BOOKING_SEL_CAT > 0 )); then BOOKING_SEL_CAT=$(( BOOKING_SEL_CAT - 1 )); fi
        elif (( BOOKING_DEPTH == 1 )); then
          if (( BOOKING_SEL_ROOM > 0 )); then BOOKING_SEL_ROOM=$(( BOOKING_SEL_ROOM - 1 )); fi
        else
          if (( BOOKING_SEL_SLOT > 0 )); then BOOKING_SEL_SLOT=$(( BOOKING_SEL_SLOT - 1 )); fi
        fi
      elif (( BOOKING_TAB == 1 )); then
        if (( BOOKING_OWN_SEL > 0 )); then BOOKING_OWN_SEL=$(( BOOKING_OWN_SEL - 1 )); fi
      else
        if (( BOOKING_PENDING_SEL > 0 )); then BOOKING_PENDING_SEL=$(( BOOKING_PENDING_SEL - 1 )); fi
      fi
      ;;
    DOWN)
      if (( BOOKING_TAB == 0 )); then
        if (( BOOKING_DEPTH == 0 )); then
          total="$(_booking_categories_count)"
          if (( total > 0 && BOOKING_SEL_CAT < total - 1 )); then BOOKING_SEL_CAT=$(( BOOKING_SEL_CAT + 1 )); fi
        elif (( BOOKING_DEPTH == 1 )); then
          total="$(_booking_rooms_count)"
          if (( total > 0 && BOOKING_SEL_ROOM < total - 1 )); then BOOKING_SEL_ROOM=$(( BOOKING_SEL_ROOM + 1 )); fi
        else
          total="$(_booking_slots_count)"
          if (( total > 0 && BOOKING_SEL_SLOT < total - 1 )); then BOOKING_SEL_SLOT=$(( BOOKING_SEL_SLOT + 1 )); fi
        fi
      elif (( BOOKING_TAB == 1 )); then
        total="$(_booking_own_count)"
        if (( total > 0 && BOOKING_OWN_SEL < total - 1 )); then BOOKING_OWN_SEL=$(( BOOKING_OWN_SEL + 1 )); fi
      else
        total="$(_booking_pending_count)"
        if (( total > 0 && BOOKING_PENDING_SEL < total - 1 )); then BOOKING_PENDING_SEL=$(( BOOKING_PENDING_SEL + 1 )); fi
      fi
      ;;
    ENTER)
      if (( BOOKING_TAB == 0 )); then
        if (( BOOKING_DEPTH == 0 )); then
          BOOKING_SEL_CAT_ID="$(printf '%s' "${BOOKING_CATEGORIES}" | jq -r '.['"${BOOKING_SEL_CAT}"'].id // empty' 2>/dev/null || true)"
          if core_is_blank "${BOOKING_SEL_CAT_ID}"; then core_err "请选择分类。"; return 0; fi
          BOOKING_ROOMS_DATA=""
          BOOKING_SEL_ROOM=0
          BOOKING_DEPTH=1
          _booking_start_fetch rooms "${BOOKING_SEL_CAT_ID}"
        elif (( BOOKING_DEPTH == 1 )); then
          BOOKING_DATE_OFF=0
          BOOKING_DEPTH=2
          _booking_precompute_slots
        else
          _booking_do_book
        fi
      elif (( BOOKING_TAB == 1 )); then
        _booking_cancel_selected
      else
        _booking_pending_delete_selected
      fi
      ;;
    d)
      if (( BOOKING_TAB == 0 && BOOKING_DEPTH == 2 )); then
        BOOKING_DATE_OFF=$(( 1 - BOOKING_DATE_OFF ))
        _booking_precompute_slots
      fi
      ;;
    a)
      if (( BOOKING_TAB == 0 && BOOKING_DEPTH == 2 )); then
        _booking_do_autobook
      elif (( BOOKING_TAB == 2 )); then
        if [[ "$(settings_get auto_book_enabled)" == "true" ]]; then
          settings_set auto_book_enabled false
          tui_set_status "已关闭自动抢约。"
        else
          settings_set auto_book_enabled true
          tui_set_status "已开启自动抢约（后台守护将在时段放出时自动下单）。"
        fi
      fi
      ;;
  esac
}

_booking_cancel_selected() {
  local uuid
  uuid="$(printf '%s' "${BOOKING_OWN}" | jq -r '.['"${BOOKING_OWN_SEL}"'].uuid // empty' 2>/dev/null || true)"
  if core_is_blank "${uuid}"; then core_err "请选择预约。"; return 1; fi
  if ! ui_input "确认取消该预约？(y/回车=确认，其它=取消)" "" 0 1; then core_err "已取消。"; return 1; fi
  local ans="${UI_INPUT_RESULT}"
  if [[ -n "${ans}" && "${ans}" != "y" && "${ans}" != "Y" ]]; then core_err "已取消。"; return 1; fi
  tui_set_status "正在取消预约…"
  tui_render
  if booking_cancel "${uuid}"; then
    tui_set_status "取消成功。"
    BOOKING_OWN=""
    BOOKING_OWN_LOADED=0
    _booking_start_fetch own
  else
    tui_set_status "${BUPTY_ERR:-取消失败。}"
  fi
  return 0
}

_booking_pending_delete_selected() {
  local total
  total="$(_booking_pending_count)"
  if (( total == 0 )); then core_err "暂无待抢约。"; return 1; fi
  if ! ui_input "删除该待抢约？(y/回车=确认)" "" 0 1; then core_err "已取消。"; return 1; fi
  local ans="${UI_INPUT_RESULT}"
  if [[ -n "${ans}" && "${ans}" != "y" && "${ans}" != "Y" ]]; then core_err "已取消。"; return 1; fi
  booking_pending_remove "${BOOKING_PENDING_SEL}"
  BOOKING_PENDING_LOADED=0
  _booking_pending_load
  tui_set_status "已删除。"
  return 0
}
