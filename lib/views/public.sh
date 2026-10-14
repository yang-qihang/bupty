#!/usr/bin/env bash
# views/public.sh —— 公共查询视图：班车 / 节假日 / 活动 三个子页（无需登录）。
# ←/→ 切子页，↑/↓/PgUp/PgDn 滚动，r 刷新当前子页；节假日用 [ ] 或 + - 切年份。

set -euo pipefail

# 视图状态。
PUBLIC_TAB=0              # 0 班车、1 节假日、2 活动。
PUBLIC_SHUTTLE=""         # 班车 JSON（{date,status,next_departure,notice_id,notice_title,notice_url,stops,notes,stale,routes}）。
PUBLIC_HOLIDAYS=""        # 节假日 JSON（{year,source,items}）。
PUBLIC_EVENTS=""          # 活动 JSON（{source,items}）。
PUBLIC_FETCH_TAB=""       # 在途拉取的子页（""/0/1/2）。
PUBLIC_HOLIDAY_YEAR=""    # 当前选中年份（空则默认今年）。
PUBLIC_HOLIDAYS_YEAR=""   # 已加载节假日数据所属年份。
PUBLIC_SEL=0              # 活动选中行。
PUBLIC_OFFSET=0           # 列表滚动偏移。
PUBLIC_EVENTS_ROWS=""     # 预计算活动行（TSV：deadline_ts、显示行），含已截止，渲染时纯 bash 过滤。
_PUBLIC_FILTER_EPOCH=""   # 活动过滤缓存对应的时间戳（秒），同秒内复用，避免每帧重扫全部条目。

# 待输出行（班车视图先收集再按窗口输出，便于整屏滚动）。
_PUBLIC_LINES=()
_PUBLIC_SHUTTLE_LINES=()      # 班车显示行缓存（含颜色，jq 只跑一次）。
_PUBLIC_SHUTTLE_LINES_VALID=0 # 班车显示行缓存是否有效。
_PUBLIC_SHUTTLE_LINES_COLS="" # 缓存各行是按哪个 UI_COLS 截断的；宽度变了缓存即失效（见 _public_precompute_shuttle）。

_public_line_add() { _PUBLIC_LINES+=("$1"); }
_public_lines_clear() { _PUBLIC_LINES=(); }

# 输出当前窗口内的行（班车子页整屏滚动）。
# body = 正文可用行数（tui_render 传下来）。班车子页**没有**任何页内固定行——
# 整个 _PUBLIC_LINES 就是可滚动窗口，所以这里 F=0，可见行数 = body。
_public_lines_print() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows public
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      body=$(( ${UI_ROWS:-24} - 5 ))
    fi
  fi
  (( body < 0 )) && body=0
  local total="${#_PUBLIC_LINES[@]}"
  local visible="${body}"
  (( visible < 1 )) && visible=1
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
# 拉取（异步；成功置缓存，失败保留旧数据并置 BUPTY_ERR）
# ---------------------------------------------------------------------------

# 当前子页缓存为空时，后台拉取当前子页；切换子页时取消其它子页的在途拉取。
_public_start_fetch() {
  if [[ -n "${TUI_FETCH_PID}" ]]; then
    # 其它视图的在途拉取不打断；公共查询在途拉取属于当前子页时等它完成。
    if [[ "${TUI_FETCH_VIEW}" != "public" || "${PUBLIC_FETCH_TAB}" == "${PUBLIC_TAB}" ]]; then
      return 0
    fi
    # 在途的公共查询拉取属于其它子页 → 取消，改为立即拉取当前子页。
    _async_stop
    PUBLIC_FETCH_TAB=""
  fi
  case "${PUBLIC_TAB}" in
    1) [[ -n "${PUBLIC_HOLIDAYS}" ]] && return 0
       PUBLIC_FETCH_TAB=1
       _async_start public public_fetch_holidays "$(_public_holiday_year)" ;;
    2) [[ -n "${PUBLIC_EVENTS}" ]] && return 0
       PUBLIC_FETCH_TAB=2
       _async_start public public_fetch_events ;;
    *) [[ -n "${PUBLIC_SHUTTLE}" ]] && return 0
       PUBLIC_FETCH_TAB=0
       _async_start public public_fetch_shuttle ;;
  esac
}

# 后台拉取完成回调：读取数据并更新对应子页缓存。
apply_public() {
  local file="$1" data
  data="$(cat "${file}" 2>/dev/null || true)"
  if [[ "${data}" == ERROR:* ]]; then
    core_err "${data#ERROR:}"
  elif [[ -n "${data}" ]]; then
    case "${PUBLIC_FETCH_TAB}" in
      1) PUBLIC_HOLIDAYS="${data}"
         PUBLIC_HOLIDAYS_YEAR="$(printf '%s' "${data}" | jq -r '.year // empty' 2>/dev/null || true)" ;;
      2) PUBLIC_EVENTS="${data}"; _public_precompute_events ;;
      *) PUBLIC_SHUTTLE="${data}"; _PUBLIC_SHUTTLE_LINES_VALID=0 ;;
    esac
    core_clear_err
  else
    core_err "加载失败。"
  fi
  PUBLIC_FETCH_TAB=""
  return 0
}

# ---------------------------------------------------------------------------
# 班车子页
# ---------------------------------------------------------------------------

# 预计算班车显示行（jq 只跑一次，缓存到 _PUBLIC_SHUTTLE_LINES，避免每次渲染重复 fork）。
# 取 theirs：本分支旧版那份同步的 _public_render_shuttle 已被下方异步版整段取代，这里不再
# 保留第二份定义（同名函数后者会赢，等于把新结构整个丢掉）。只把旧版的宽度护栏搬过来：
# 每行先 core_clip 再 ui_paint（core_clip 必须套在**未着色**的原文上，ANSI 转义不占列，
# 套在着色后的串上会把颜色码算成宽度）。代价是缓存里存的是按当时 UI_COLS 截断好的行，
# 因此把宽度也并入缓存有效性判断：终端一变宽窄就按新宽度重算一次（jq 仍只在数据变或
# 宽度变时各跑一次，远少于每帧一次），否则窄化后会用旧宽度的行顶出右边界。
_public_precompute_shuttle() {
  if [[ "${_PUBLIC_SHUTTLE_LINES_VALID}" == "1" && "${_PUBLIC_SHUTTLE_LINES_COLS}" == "${UI_COLS}" ]]; then
    return 0
  fi
  _PUBLIC_SHUTTLE_LINES=()
  _PUBLIC_SHUTTLE_LINES_COLS="${UI_COLS}"
  local date status next stale notice_title
  date="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.date // ""' 2>/dev/null || true)"
  status="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.status // ""' 2>/dev/null || true)"
  next="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.next_departure // ""' 2>/dev/null || true)"
  stale="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.stale // "false"' 2>/dev/null || true)"
  notice_title="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.notice_title // ""' 2>/dev/null || true)"
  _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint title "$(core_clip "班车 · ${date} · ${status}" "$((UI_COLS - 1))")")")
  if [[ "${stale}" == "true" ]]; then
    _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint warning "$(core_clip '  提示：服务当前返回缓存数据，请以学校通知为准。' "$((UI_COLS - 1))")")")
  fi
  # notice_title / next 都是服务端文本，同样夹 core_clip（旧版对 next 那一行就是这么夹的，
  # 换成缓存写法后不能漏掉）。
  if [[ -n "${notice_title}" ]]; then
    _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint muted "$(core_clip "  生效通知：${notice_title}" "$((UI_COLS - 1))")")")
  fi
  if [[ -n "${next}" ]]; then
    _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint success "$(core_clip "  ${next}" "$((UI_COLS - 1))")")")
  fi
  _PUBLIC_SHUTTLE_LINES+=("")

  local routes_n i
  routes_n="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r 'if (.routes|type)=="array" then (.routes|length|tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${routes_n}" || "${routes_n}" == "null" ]]; then routes_n=0; fi
  if (( routes_n == 0 )); then
    # 取 theirs 的缓存写法（这段就在 _public_precompute_shuttle 里，输出到 _PUBLIC_LINES 是
    # 旧版同步渲染的做法），保留 ours 的 core_clip 护栏。
    _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint muted "$(core_clip '  暂无班车安排。' "$((UI_COLS - 1))")")")
    _PUBLIC_SHUTTLE_LINES_VALID=1
    return 0
  fi

  local j n row from to label dep time vehicle count departed nxt txt
  for ((i = 0; i < routes_n; i++)); do
    row="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -c '.routes['"${i}"']' 2>/dev/null || true)"
    [[ -z "${row}" || "${row}" == "null" ]] && continue
    from="$(printf '%s' "${row}" | jq -r '.from // ""' 2>/dev/null || true)"
    to="$(printf '%s' "${row}" | jq -r '.to // ""' 2>/dev/null || true)"
    label="$(printf '%s' "${row}" | jq -r '.period_label // ""' 2>/dev/null || true)"
    # 同上：缓存写法取 theirs，core_clip 护栏取 ours（路线名来自服务端，可能很长）。
    _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint accent "$(core_clip "${from} → ${to}" "$((UI_COLS - 1))")")")
    if [[ -n "${label}" ]]; then
      _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint muted "$(core_clip "  ${label}" "$((UI_COLS - 1))")")")
    fi
    n="$(printf '%s' "${row}" | jq -r 'if (.departures|type)=="array" then (.departures|length|tostring) else "0" end' 2>/dev/null || true)"
    if [[ -z "${n}" || "${n}" == "null" ]]; then n=0; fi
    for ((j = 0; j < n; j++)); do
      dep="$(printf '%s' "${row}" | jq -c '.departures['"${j}"']' 2>/dev/null || true)"
      time="$(printf '%s' "${dep}" | jq -r '.time // ""' 2>/dev/null || true)"
      vehicle="$(printf '%s' "${dep}" | jq -r '.vehicle // ""' 2>/dev/null || true)"
      count="$(printf '%s' "${dep}" | jq -r '.count // 0' 2>/dev/null || true)"
      departed="$(printf '%s' "${dep}" | jq -r '.departed // false' 2>/dev/null || true)"
      nxt="$(printf '%s' "${dep}" | jq -r '.next // false' 2>/dev/null || true)"
      txt="${time}  ${vehicle}×${count}"
      # 变量名取 theirs 的 nxt：同一函数里 next 已表示「下一班发车」(next_departure)，
      # 旧版在这里复用它只是碰巧没被后面用到；沿用 nxt 才不会有影子变量。
      # 三个分支都保留 ours 的 core_clip（车辆/时间来自服务端）。
      if [[ "${nxt}" == "true" ]]; then
        _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint success "$(core_clip "▶ ${txt}" "$((UI_COLS - 1))")")")
      elif [[ "${departed}" == "true" ]]; then
        _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint muted "$(core_clip "  ${txt}" "$((UI_COLS - 1))")")")
      else
        _PUBLIC_SHUTTLE_LINES+=("$(core_clip "   ${txt}" "${UI_COLS}")")
      fi
    done
  done

  # 发车地点（stops）与温馨提示（notes）。
  local stops_n
  stops_n="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r 'if (.stops | type) == "array" then (.stops | length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${stops_n}" || "${stops_n}" == "null" ]]; then stops_n=0; fi
  if (( stops_n > 0 )); then
    _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint title '发车地点')")
    local stop_line campus location
    while IFS= read -r stop_line; do
      [[ -z "${stop_line}" ]] && continue
      campus="$(printf '%s' "${stop_line}" | jq -r '.campus // ""' 2>/dev/null || true)"
      location="$(printf '%s' "${stop_line}" | jq -r '.location // ""' 2>/dev/null || true)"
      # 地点/提示同样来自服务端，统一过 core_clip（这几个分支是 theirs 新增的，
      # 但既然缓存里其它行都截断了，这里不截就会在窄终端上单独顶出右边界）。
      _PUBLIC_SHUTTLE_LINES+=("$(core_clip "   ${campus}：${location}" "${UI_COLS}")")
    done < <(printf '%s' "${PUBLIC_SHUTTLE}" | jq -c '.stops[]?' 2>/dev/null || true)
  fi

  local notes_n
  notes_n="$(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r 'if (.notes | type) == "array" then (.notes | length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${notes_n}" || "${notes_n}" == "null" ]]; then notes_n=0; fi
  if (( notes_n > 0 )); then
    local note
    while IFS= read -r note; do
      [[ -n "${note}" ]] && _PUBLIC_SHUTTLE_LINES+=(" $(ui_paint muted "$(core_clip "  提示：${note}" "$((UI_COLS - 1))")")")
    done < <(printf '%s' "${PUBLIC_SHUTTLE}" | jq -r '.notes[]? // empty' 2>/dev/null || true)
  fi
  _PUBLIC_SHUTTLE_LINES_VALID=1
}

_public_render_shuttle() {
  local body="${1:-}"
  _public_lines_clear
  if [[ -z "${PUBLIC_SHUTTLE}" ]]; then
    # 整体取 theirs 的异步三态；三条文本按 ours 的规矩补上 core_clip
    # （三态文案本来就是 ours 在冲突块里逐条夹过 core_clip 的，不能因为换了渲染路径就丢）。
    if [[ -n "${TUI_FETCH_PID}" && "${PUBLIC_FETCH_TAB}" == "0" ]]; then
      _public_line_add " $(ui_paint muted "$(core_clip '  正在加载…' "$((UI_COLS - 1))")")"
    elif [[ -n "${BUPTY_ERR}" ]]; then
      _public_line_add " $(ui_paint danger "$(core_clip '  班车加载失败，请查看底部错误信息。' "$((UI_COLS - 1))")")"
    else
      _public_line_add " $(ui_paint muted "$(core_clip '  暂无班车数据 · 按 r 刷新' "$((UI_COLS - 1))")")"
    fi
    _public_lines_print "${body}"
    return 0
  fi
  _public_precompute_shuttle
  _PUBLIC_LINES=("${_PUBLIC_SHUTTLE_LINES[@]}")
  _public_lines_print "${body}"
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

# 节假日子页。body = 正文可用行数；本页固定 3 行（空行 + 信息行 + 空行），F=3
# 是实测值（列表只放 1 条、UI_ROWS=1000 时正文 4 行）。
_public_render_holidays() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows public
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      body=$(( ${UI_ROWS:-24} - 5 ))
    fi
  fi
  (( body < 0 )) && body=0
  printf '\n'
  if [[ -z "${PUBLIC_HOLIDAYS}" ]]; then
    # 取 theirs：新增的「在途拉取中」分支（异步改造的核心，旧版没有），三态顺序照搬；
    # 每条打印文本仍按 ours 的规矩过一遍 core_clip，窄终端下不顶出右边界。
    if [[ -n "${TUI_FETCH_PID}" && "${PUBLIC_FETCH_TAB}" == "1" ]]; then
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  正在加载…' "$((UI_COLS - 1))")")"
    elif [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger "$(core_clip '  节假日加载失败，请查看底部错误信息。' "$((UI_COLS - 1))")")"
    else
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无节假日数据 · 按 r 刷新' "$((UI_COLS - 1))")")"
    fi
    return 0
  fi

  local year total
  year="$(_public_holiday_year)"
  total="$(_public_holidays_count)"
  printf ' %s\n' "$(ui_paint muted "$(core_clip "节假日 · ${year} 年 · 共 ${total} 条 · [ ] 或 + - 切年份 · ↑↓ 滚动 · r 刷新" "$((UI_COLS - 1))")")"
  printf '\n'

  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted "$(core_clip '  该年份暂无节假日数据。' "$((UI_COLS - 1))")")"
    return 0
  fi

  local items visible offset end i row date name type tag line
  items="$(_public_holidays_items)"
  # 列表可见行 = 正文预算 - 本页固定 3 行；极小窗口下至少留 1 行。
  visible=$((body - 3))
  (( visible < 1 )) && visible=1
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
      printf '   %s\n' "$(ui_paint muted "$(core_fit "${line}" "$((UI_COLS - 3))")")"
    else
      printf '   %s\n' "$(core_fit "${line}" "$((UI_COLS - 3))")"
    fi
  done
}

# ---------------------------------------------------------------------------
# 活动子页
# ---------------------------------------------------------------------------

# 预计算活动行（一次 jq，含已截止，按 deadline_ts/name 升序）。渲染时纯 bash 过滤。
_public_precompute_events() {
  PUBLIC_EVENTS_ROWS=""
  _PUBLIC_FILTER_EPOCH=""   # 数据已变，失效过滤缓存。
  if [[ -z "${PUBLIC_EVENTS}" ]]; then
    return 0
  fi
  PUBLIC_EVENTS_ROWS="$(printf '%s' "${PUBLIC_EVENTS}" | jq -r '
    [.items[]?] | sort_by(.deadline_ts, .name)
    | .[]
    | ((.categories // []) | join("/")) as $cat
    | (.organizer // "") as $org
    | ($cat + (if $org != "" then " · " + $org else "" end)) as $meta
    | ((.primary_deadline // "")[0:10]) as $date_disp
    | ($date_disp + "  " + (.name // "") + (if $meta != "" then " · " + $meta else "" end)) as $line
    | [ (.deadline_ts // 0), ($line | gsub("[\t\r\n]"; " ")) ]
    | join("\u001f")
  ' 2>/dev/null || true)"
}

# 过滤未截止活动（纯 bash，数值比较 deadline_ts），输出到 _PUBLIC_VISIBLE_ROWS。
# 同一秒内复用缓存（活动可多达数百条，避免每帧重扫导致卡顿）。
_public_events_filter() {
  local now_epoch
  now_epoch="$(date +%s)"
  if [[ "${_PUBLIC_FILTER_EPOCH:-}" == "${now_epoch}" ]]; then
    return 0
  fi
  _PUBLIC_FILTER_EPOCH="${now_epoch}"
  _PUBLIC_VISIBLE_ROWS=()
  _PUBLIC_VISIBLE_COUNT=0
  if [[ -z "${PUBLIC_EVENTS_ROWS}" ]]; then
    return 0
  fi
  local -a all=()
  readarray -t all <<< "${PUBLIC_EVENTS_ROWS}"
  local i ts line
  for ((i = 0; i < ${#all[@]}; i++)); do
    # 用参数展开切分 TSV，避免每条一次 herestring（fork）。
    ts="${all[$i]%%$'\x1f'*}"
    line="${all[$i]#*$'\x1f'}"
    if [[ "${ts}" =~ ^[0-9]+$ ]] && (( ts >= now_epoch )); then
      _PUBLIC_VISIBLE_ROWS+=("${line}")
    fi
  done
  _PUBLIC_VISIBLE_COUNT="${#_PUBLIC_VISIBLE_ROWS[@]}"
}

_public_events_count() {
  _public_events_filter
  printf '%s' "${_PUBLIC_VISIBLE_COUNT}"
}

_public_render_event_row() {
  local i="$1"
  local line="${_PUBLIC_VISIBLE_ROWS[$i]:-}"
  [[ -z "${line}" ]] && return 0
  if [[ "${i}" -eq "${PUBLIC_SEL}" ]]; then
    _core_fit_compute "${line}" "$((UI_COLS - 3))"
    printf ' %s› %s%s\n' "${UI_HL_FG}" "${_CORE_FIT_OUT}" "${UI_RESET}"
  else
    _core_fit_compute "${line}" "$((UI_COLS - 3))"
    printf '   %s\n' "${_CORE_FIT_OUT}"
  fi
}

# 活动子页。body = 正文可用行数；本页固定 3 行（空行 + 信息行 + 空行），F=3（实测同上）。
_public_render_events() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows public
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      body=$(( ${UI_ROWS:-24} - 5 ))
    fi
  fi
  (( body < 0 )) && body=0
  printf '\n'
  if [[ -z "${PUBLIC_EVENTS}" ]]; then
    # 同节假日子页：theirs 的三态（含「正在加载…」），ours 的 core_clip 护栏。
    if [[ -n "${TUI_FETCH_PID}" && "${PUBLIC_FETCH_TAB}" == "2" ]]; then
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  正在加载…' "$((UI_COLS - 1))")")"
    elif [[ -n "${BUPTY_ERR}" ]]; then
      printf ' %s\n' "$(ui_paint danger "$(core_clip '  活动加载失败，请查看底部错误信息。' "$((UI_COLS - 1))")")"
    else
      printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无活动数据 · 按 r 刷新' "$((UI_COLS - 1))")")"
    fi
    return 0
  fi

  _public_events_filter
  local total
  total="${_PUBLIC_VISIBLE_COUNT}"
  printf ' %s\n' "$(ui_paint muted "$(core_clip "活动 · 未截止 ${total} 条 · ↑↓ 选择 · PgUp/PgDn 翻页 · r 刷新" "$((UI_COLS - 1))")")"
  printf '\n'

  if (( total == 0 )); then
    printf ' %s\n' "$(ui_paint muted "$(core_clip '  暂无未截止的活动。' "$((UI_COLS - 1))")")"
    return 0
  fi

  local visible offset end i
  # 列表可见行 = 正文预算 - 本页固定 3 行；极小窗口下至少留 1 行。
  visible=$((body - 3))
  (( visible < 1 )) && visible=1
  if (( PUBLIC_SEL >= total )); then PUBLIC_SEL=$((total - 1)); fi
  if (( PUBLIC_SEL < 0 )); then PUBLIC_SEL=0; fi
  offset="${PUBLIC_OFFSET:-0}"
  if (( PUBLIC_SEL < offset )); then offset=${PUBLIC_SEL}; fi
  if (( PUBLIC_SEL >= offset + visible )); then offset=$((PUBLIC_SEL - visible + 1)); fi
  PUBLIC_OFFSET="${offset}"
  end=$((offset + visible))
  (( end > total )) && end=${total}
  for ((i = offset; i < end; i++)); do
    _public_render_event_row "${i}"
  done
}

# ---------------------------------------------------------------------------
# 视图入口
# ---------------------------------------------------------------------------

# 进入视图渲染。公共查询无需登录；进入自动拉取当前子页，r 强制刷新。
# body = 正文可用行数，由 tui_render 传入；直接调用（测试）时按唯一口径自行推导。
render_public() {
  local body="${1:-}"
  if [[ -z "${body}" ]]; then
    if declare -F banner_chrome_rows >/dev/null 2>&1; then
      banner_chrome_rows public
      body=$(( UI_ROWS - BANNER_CHROME_ROWS ))
    else
      body=$(( ${UI_ROWS:-24} - 5 ))
    fi
  fi
  (( body < 0 )) && body=0
  _public_start_fetch
  case "${PUBLIC_TAB}" in
    1) _public_render_holidays "${body}" ;;
    2) _public_render_events "${body}" ;;
    *) _public_render_shuttle "${body}" ;;
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
      # 强制刷新：清空当前子页缓存，交由下一帧 render_public 自动重拉。
      case "${PUBLIC_TAB}" in
        1) PUBLIC_HOLIDAYS=""; PUBLIC_HOLIDAYS_YEAR="" ;;
        2) PUBLIC_EVENTS=""; PUBLIC_EVENTS_ROWS="" ;;
        *) PUBLIC_SHUTTLE="" ;;
      esac
      _async_stop
      PUBLIC_FETCH_TAB=""
      _public_reset_scroll
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
        # 翻页步长与渲染的可见行数同口径：body = UI_ROWS - chrome（chrome 由
        # banner_chrome_rows 唯一给出，最近一次渲染已写进 BANNER_CHROME_ROWS）。
        local body
        body=$(( UI_ROWS - ${BANNER_CHROME_ROWS:-5} ))
        (( body < 0 )) && body=0
        if [[ "${PUBLIC_TAB}" == "1" ]]; then
          visible=$((body - 3))   # 节假日子页固定 3 行
        else
          visible="${body}"       # 班车子页没有页内固定行
        fi
        (( visible < 1 )) && visible=1
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
    PUBLIC_HOLIDAYS=""
  fi
  # 无论是否切回已加载年份，都取消在途拉取，避免旧年份结果覆盖新选中年份。
  _async_stop
  PUBLIC_FETCH_TAB=""
}
