#!/usr/bin/env bash
# views/public.sh —— 公共查询视图：班车 / 节假日 / 活动 三个子页（无需登录）。
# ←/→ 切子页，↑/↓/PgUp/PgDn 滚动，r 刷新当前子页；节假日用 [ ] 或 + - 切年份。

set -euo pipefail

# 视图状态。
PUBLIC_TAB=0              # 0 班车、1 节假日、2 活动。
PUBLIC_SHUTTLE=""         # 班车 JSON（{date,status,next_departure,notice_title,routes}）。
PUBLIC_HOLIDAYS=""        # 节假日 JSON（{year,source,items}）。
PUBLIC_EVENTS=""          # 活动 JSON（{source,items}）。
PUBLIC_LOADED_SHUTTLE=0
PUBLIC_LOADED_HOLIDAYS=0
PUBLIC_LOADED_EVENTS=0
PUBLIC_HOLIDAY_YEAR=""    # 当前选中年份（空则默认今年）。
PUBLIC_HOLIDAYS_YEAR=""   # 已加载节假日数据所属年份。
PUBLIC_SEL=0              # 活动选中行。
PUBLIC_OFFSET=0           # 列表滚动偏移。

# 待输出行（班车视图先收集再按窗口输出，便于整屏滚动）。
_PUBLIC_LINES=()

_public_line_add() { _PUBLIC_LINES+=("$1"); }
_public_lines_clear() { _PUBLIC_LINES=(); }

_public_lines_print() {
  local total="${#_PUBLIC_LINES[@]}"
  local visible=$((UI_ROWS - 6))
  (( visible < 4 )) && visible=4
  local offset="${PUBLIC_OFFSET:-0}"
  if (( offset > total - visible )); then offset=$((total - visible)); fi
  if (( offset < 0 )); then offset=0; fi
  PUBLIC_OFFSET="${offset}"
  local end=$((offset + visible))
  (( end > total )) && end=${total}
  local i
  for ((i = offset; i < end; i++)); do
    printf '%s\n' "${_PUBLIC_LINES[$i]}"
  done
}

# 当前节假日年份（默认今年）。
_public_holiday_year() {
  if [[ -z "${PUBLIC_HOLIDAY_YEAR:-}" ]]; then
    PUBLIC_HOLIDAY_YEAR="$(core_today | cut -d- -f1)"
  fi
  printf '%s' "${PUBLIC_HOLIDAY_YEAR}"
}

_public_reset_scroll() {
  PUBLIC_SEL=0
  PUBLIC_OFFSET=0
}

# ---------------------------------------------------------------------------
# 拉取（不渲染；成功置缓存，失败保留旧数据并置 BUPTY_ERR）
# ---------------------------------------------------------------------------

_public_fetch_shuttle() {
  local tmp data
  tmp="$(mktemp)"
  if public_fetch_shuttle > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    PUBLIC_SHUTTLE="${data}"
    PUBLIC_LOADED_SHUTTLE=1
    core_clear_err
    return 0
  fi
  rm -f "${tmp}"
  PUBLIC_LOADED_SHUTTLE=1
  return 1
}

_public_fetch_holidays() {
  local year tmp data
  year="$(_public_holiday_year)"
  tmp="$(mktemp)"
  if public_fetch_holidays "${year}" > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    PUBLIC_HOLIDAYS="${data}"
    PUBLIC_HOLIDAYS_YEAR="${year}"
    PUBLIC_LOADED_HOLIDAYS=1
    core_clear_err
    return 0
  fi
  rm -f "${tmp}"
  PUBLIC_HOLIDAYS_YEAR="${year}"
  PUBLIC_LOADED_HOLIDAYS=1
  return 1
}

_public_fetch_events() {
  local tmp data
  tmp="$(mktemp)"
  if public_fetch_events > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    PUBLIC_EVENTS="${data}"
    PUBLIC_LOADED_EVENTS=1
    core_clear_err
    return 0
  fi
  rm -f "${tmp}"
  PUBLIC_LOADED_EVENTS=1
  return 1
}

# 刷新当前子页。
public_refresh() {
  case "${PUBLIC_TAB}" in
    1)
      tui_set_status "正在加载节假日…"
      tui_render
      if _public_fetch_holidays; then tui_set_status "节假日已更新。"; fi
      ;;
    2)
      tui_set_status "正在加载活动…"
      tui_render
      if _public_fetch_events; then tui_set_status "活动已更新。"; fi
      ;;
    *)
      tui_set_status "正在加载班车…"
      tui_render
      if _public_fetch_shuttle; then tui_set_status "班车已更新。"; fi
      ;;
  esac
  _public_reset_scroll
  tui_render
  return 0
}

# ---------------------------------------------------------------------------
# 班车子页
# ---------------------------------------------------------------------------

_public_render_shuttle() {
  _public_lines_clear
  if [[ -z "${PUBLIC_SHUTTLE}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      _public_line_add " $(ui_paint danger '  班车加载失败，请查看底部错误信息。')"
    else
      _public_line_add " $(ui_paint muted '  暂无班车数据 · 按 r 刷新')"
    fi
    _public_lines_print
    return 0
  fi

  local date status next
  date="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.date // ""' 2>/dev/null || true)"
  status="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.status // ""' 2>/dev/null || true)"
  next="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.next_departure // ""' 2>/dev/null || true)"
  _public_line_add " $(ui_paint title "班车 · ${date} · ${status}")"
  if [[ -n "${next}" ]]; then
    _public_line_add " $(ui_paint success "  ${next}")"
  fi
  _public_line_add ""

  local routes_n i
  routes_n="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r 'if (.routes|type)=="array" then (.routes|length|tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${routes_n}" || "${routes_n}" == "null" ]]; then routes_n=0; fi
  if (( routes_n == 0 )); then
    _public_line_add " $(ui_paint muted '  暂无班车安排。')"
    _public_lines_print
    return 0
  fi

  local j n row from to label dep time vehicle count departed next txt
  for ((i = 0; i < routes_n; i++)); do
    row="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -c '.routes['"${i}"']' 2>/dev/null || true)"
    [[ -z "${row}" || "${row}" == "null" ]] && continue
    from="$(printf '%s' "${row}" | jq -r '.from // ""' 2>/dev/null || true)"
    to="$(printf '%s' "${row}" | jq -r '.to // ""' 2>/dev/null || true)"
    label="$(printf '%s' "${row}" | jq -r '.period_label // ""' 2>/dev/null || true)"
    _public_line_add " $(ui_paint accent "${from} → ${to}")"
    if [[ -n "${label}" ]]; then
      _public_line_add " $(ui_paint muted "  ${label}")"
    fi
    n="$(printf '%s' "${row}" | jq -r 'if (.departures|type)=="array" then (.departures|length|tostring) else "0" end' 2>/dev/null || true)"
    if [[ -z "${n}" || "${n}" == "null" ]]; then n=0; fi
    for ((j = 0; j < n; j++)); do
      dep="$(printf '%s' "${row}" | jq -c '.departures['"${j}"']' 2>/dev/null || true)"
      time="$(printf '%s' "${dep}" | jq -r '.time // ""' 2>/dev/null || true)"
      vehicle="$(printf '%s' "${dep}" | jq -r '.vehicle // ""' 2>/dev/null || true)"
      count="$(printf '%s' "${dep}" | jq -r '.count // 0' 2>/dev/null || true)"
      departed="$(printf '%s' "${dep}" | jq -r '.departed // false' 2>/dev/null || true)"
      next="$(printf '%s' "${dep}" | jq -r '.next // false' 2>/dev/null || true)"
      txt="${time}  ${vehicle}×${count}"
      if [[ "${next}" == "true" ]]; then
        _public_line_add " $(ui_paint success "▶ ${txt}")"
      elif [[ "${departed}" == "true" ]]; then
        _public_line_add " $(ui_paint muted "  ${txt}")"
      else
        _public_line_add "   ${txt}"
      fi
    done
  done
  _public_lines_print
}

# ---------------------------------------------------------------------------
# 节假日子页
# ---------------------------------------------------------------------------

_public_holidays_items() {
  printf '%s' "${PUBLIC_HOLIDAYS}" | jq -c '.items // []' 2>/dev/null || true
}

_public_holidays_count() {
  local n
  n="$(printf '%s' "$(_public_holidays_items)" | jq -r 'if type=="array" then (length|tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${n}" || "${n}" == "null" ]]; then printf '0'; else printf '%s' "${n}"; fi
}

_public_render_holidays() {
  printf '\n'
  if [[ -z "${PUBLIC_HOLIDAYS}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger '  节假日加载失败，请查看底部错误信息。')"
    else
      printf ' %s\n' "$(ui_paint muted '  暂无节假日数据 · 按 r 刷新')"
    fi
    return 0
  fi

  local year total
  year="$(_public_holiday_year)"
  total="$(_public_holidays_count)"
  printf ' %s\n' "$(ui_paint muted "节假日 · ${year} 年 · 共 ${total} 条 · [ ] 或 + - 切年份 · ↑↓ 滚动 · r 刷新")"
  printf '\n'

  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted '  该年份暂无节假日数据。')"
    return 0
  fi

  local items visible offset end i row date name type tag line
  items="$(_public_holidays_items)"
  visible=$((UI_ROWS - 7))
  (( visible < 4 )) && visible=4
  offset="${PUBLIC_OFFSET:-0}"
  if (( offset > total - visible )); then offset=$((total - visible)); fi
  if (( offset < 0 )); then offset=0; fi
  PUBLIC_OFFSET="${offset}"
  end=$((offset + visible))
  (( end > total )) && end=${total}
  for ((i = offset; i < end; i++)); do
    row="$(printf '%s' "${items}" | jq -c '.['"${i}"']' 2>/dev/null || true)"
    [[ -z "${row}" || "${row}" == "null" ]] && continue
    date="$(printf '%s' "${row}" | jq -r '.date // ""' 2>/dev/null || true)"
    name="$(printf '%s' "${row}" | jq -r '.name // ""' 2>/dev/null || true)"
    type="$(printf '%s' "${row}" | jq -r '.type // ""' 2>/dev/null || true)"
    if [[ "${type}" == "workday" ]]; then tag="班"; else tag="休"; fi
    line="${date}  ${name}  [${tag}]"
    if [[ "${type}" == "workday" ]]; then
      printf '   %s\n' "$(ui_paint muted "$(core_fit "${line}" "$((UI_COLS - 6))")")"
    else
      printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 6))")"
    fi
  done
}

# ---------------------------------------------------------------------------
# 活动子页
# ---------------------------------------------------------------------------

# 未截止活动（视图层过滤已截止），按截止升序。
_public_events_visible() {
  local now_rfc
  now_rfc="$(core_now_rfc3339)"
  printf '%s' "${PUBLIC_EVENTS}" | jq -c --arg now "${now_rfc}" \
    '[.items[]? | select(.primary_deadline >= $now)] | sort_by(.primary_deadline, .name)' 2>/dev/null || true
}

_public_events_count() {
  local n
  n="$(printf '%s' "$(_public_events_visible)" | jq -r 'if type=="array" then (length|tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${n}" || "${n}" == "null" ]]; then printf '0'; else printf '%s' "${n}"; fi
}

_public_render_event_row() {
  local i="$1" items="$2"
  local row name pd cat org line date_disp meta
  row="$(printf '%s' "${items}" | jq -c '.['"${i}"']' 2>/dev/null || true)"
  [[ -z "${row}" || "${row}" == "null" ]] && return 0
  name="$(printf '%s' "${row}" | jq -r '.name // ""' 2>/dev/null || true)"
  pd="$(printf '%s' "${row}" | jq -r '.primary_deadline // ""' 2>/dev/null || true)"
  cat="$(printf '%s' "${row}" | jq -r '(.categories // []) | join("/")' 2>/dev/null || true)"
  org="$(printf '%s' "${row}" | jq -r '.organizer // ""' 2>/dev/null || true)"
  date_disp="${pd:0:10}"
  meta="${cat}"
  [[ -n "${org}" ]] && meta="${meta} · ${org}"
  line="${date_disp}  ${name}"
  [[ -n "${meta}" ]] && line+=" · ${meta}"
  if [[ "${i}" -eq "${PUBLIC_SEL}" ]]; then
    printf ' %s\n' "$(ui_paint hl "› $(core_fit "${line}" "$((UI_COLS - 4))")")"
  else
    printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 6))")"
  fi
}

_public_render_events() {
  printf '\n'
  if [[ -z "${PUBLIC_EVENTS}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger '  活动加载失败，请查看底部错误信息。')"
    else
      printf ' %s\n' "$(ui_paint muted '  暂无活动数据 · 按 r 刷新')"
    fi
    return 0
  fi

  local total
  total="$(_public_events_count)"
  printf ' %s\n' "$(ui_paint muted "活动 · 未截止 ${total} 条 · ↑↓ 选择 · PgUp/PgDn 翻页 · r 刷新")"
  printf '\n'

  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted '  暂无未截止的活动。')"
    return 0
  fi

  local items visible offset end i
  items="$(_public_events_visible)"
  visible=$((UI_ROWS - 7))
  (( visible < 4 )) && visible=4
  if (( PUBLIC_SEL >= total )); then PUBLIC_SEL=$((total - 1)); fi
  if (( PUBLIC_SEL < 0 )); then PUBLIC_SEL=0; fi
  offset="${PUBLIC_OFFSET:-0}"
  if (( PUBLIC_SEL < offset )); then offset=${PUBLIC_SEL}; fi
  if (( PUBLIC_SEL >= offset + visible )); then offset=$((PUBLIC_SEL - visible + 1)); fi
  PUBLIC_OFFSET="${offset}"
  end=$((offset + visible))
  (( end > total )) && end=${total}
  for ((i = offset; i < end; i++)); do
    _public_render_event_row "${i}" "${items}"
  done
}

# ---------------------------------------------------------------------------
# 视图入口
# ---------------------------------------------------------------------------

# 进入视图渲染。公共查询无需登录；首次进入显示加载提示，按 r 拉取数据。
render_public() {
  case "${PUBLIC_TAB}" in
    1) _public_render_holidays ;;
    2) _public_render_events ;;
    *) _public_render_shuttle ;;
  esac
}

# 按键处理：←/→ 切子页、↑/↓/PgUp/PgDn 滚动、r 刷新、[ ] + - 切年份。
handle_public_key() {
  local key="$1"
  local total visible
  case "${key}" in
    LEFT)
      PUBLIC_TAB=$(( (PUBLIC_TAB + 2) % 3 ))
      _public_reset_scroll
      ;;
    RIGHT)
      PUBLIC_TAB=$(( (PUBLIC_TAB + 1) % 3 ))
      _public_reset_scroll
      ;;
    r)
      public_refresh
      ;;
    '['|']'|'+'|'-')
      # 仅节假日子页响应年份切换，避免其它子页误触发。
      if [[ "${PUBLIC_TAB}" == "1" ]]; then
        _public_handle_year "${key}"
      fi
      ;;
    UP|DOWN|PGUP|PGDN)
      if [[ "${PUBLIC_TAB}" == "2" ]]; then
        total="$(_public_events_count)"
        case "${key}" in
          UP)
            if (( PUBLIC_SEL > 0 )); then PUBLIC_SEL=$((PUBLIC_SEL - 1)); fi
            ;;
          DOWN)
            if (( total > 0 && PUBLIC_SEL < total - 1 )); then PUBLIC_SEL=$((PUBLIC_SEL + 1)); fi
            ;;
          PGUP)
            PUBLIC_SEL=$((PUBLIC_SEL - 10)); if (( PUBLIC_SEL < 0 )); then PUBLIC_SEL=0; fi
            ;;
          PGDN)
            PUBLIC_SEL=$((PUBLIC_SEL + 10))
            if (( total > 0 && PUBLIC_SEL >= total )); then PUBLIC_SEL=$((total - 1)); fi
            if (( PUBLIC_SEL < 0 )); then PUBLIC_SEL=0; fi
            ;;
        esac
      else
        visible=$((UI_ROWS - 7))
        (( visible < 4 )) && visible=4
        case "${key}" in
          UP) PUBLIC_OFFSET=$((PUBLIC_OFFSET - 1)) ;;
          DOWN) PUBLIC_OFFSET=$((PUBLIC_OFFSET + 1)) ;;
          PGUP) PUBLIC_OFFSET=$((PUBLIC_OFFSET - visible)) ;;
          PGDN) PUBLIC_OFFSET=$((PUBLIC_OFFSET + visible)) ;;
        esac
        if (( PUBLIC_OFFSET < 0 )); then PUBLIC_OFFSET=0; fi
      fi
      ;;
  esac
}

# 切换节假日年份。
_public_handle_year() {
  local key="$1" year
  year="$(_public_holiday_year)"
  case "${key}" in
    '['|'-') year=$((year - 1)) ;;
    ']'|'+') year=$((year + 1)) ;;
  esac
  if (( year < 1900 )); then year=1900; fi
  if (( year > 2100 )); then year=2100; fi
  PUBLIC_HOLIDAY_YEAR="${year}"
  _public_reset_scroll
  if [[ "${PUBLIC_HOLIDAYS_YEAR}" != "${year}" ]]; then
    _public_fetch_holidays
  fi
}
