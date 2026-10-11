#!/usr/bin/env bash
# views/assignments.sh —— 作业 DDL 视图：教学云作业列表与紧急程度着色、滚动选择。

set -euo pipefail

# 视图状态。
ASSIGNMENTS_DATA=""      # 作业 JSON 数组（已成功加载的数据）。
ASSIGNMENTS_ACCOUNT=""   # 数据所属账号。
ASSIGNMENTS_LOADED=0     # 是否已为当前账号加载过（含失败）。
ASSIGNMENTS_SEL=0        # 当前选中行。
ASSIGNMENTS_OFFSET=0     # 列表滚动偏移。
ASSIGNMENTS_ROWS=""      # 预计算显示行（每行 TSV：deadline_disp、days_disp、course、title、status）。
ASSIGNMENTS_COLORS=""    # 预计算每行紧急程度色（danger/warning/text）。
ASSIGNMENTS_COUNT=0      # 预计算条数。

# 是否需要（重新）加载：尚未加载，或账号已切换。
_assignments_stale() {
  [[ "${ASSIGNMENTS_LOADED}" != "1" || "${ASSIGNMENTS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]
}

# 作业条数。
_assignments_count() {
  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    printf '0'
  else
    printf '%s' "${ASSIGNMENTS_COUNT:-0}"
  fi
}

# 预计算显示数据：一次 jq 把 items 转成 TSV，渲染时纯 bash 读取。
_assignments_precompute() {
  ASSIGNMENTS_ROWS=""
  ASSIGNMENTS_COLORS=""
  ASSIGNMENTS_COUNT=0
  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    return 0
  fi
  local today combined
  today="$(core_today)"
  combined="$(printf '%s' "${ASSIGNMENTS_DATA}" | jq -r --arg today "${today}" '
    def s: gsub("[\t\r\n]"; " ");
    . as $items
    | (if ($items | type) == "array" then $items else [] end)
    | ($today | strptime("%Y-%m-%d") | mktime) as $today_ts
    | .[]
    | .deadline // "" as $dl
    | .course_name // "" as $course
    | .title // "" as $title
    | .status // "" as $status
    | ($dl | if . == "" then 0
             else (try (((($dl[0:10]) | strptime("%Y-%m-%d") | mktime) - $today_ts) / 86400) catch 0) end
             | floor) as $days
    | ($dl | if . == "" then "" else $dl[0:16] end) as $deadline_disp
    | ($dl | if . == "" then "—"
             elif $days < 0 then ("已截止 " + ((-$days) | tostring) + " 天")
             elif $days == 0 then "今天截止"
             else ("剩 " + ($days | tostring) + " 天") end) as $days_disp
    | ($dl | if . == "" then "text"
             elif $days < 0 then (if ($status == "已提交" or $status == "已批改") then "muted" else "purple" end)
             elif ($status == "已提交" or $status == "已批改") then "success"
             elif $days <= 3 then "danger"
             else "warning" end) as $color
    | [ $color, ($deadline_disp | s), ($days_disp | s), ($course | s), ($title | s), ($status | s) ]
    | join("\u001f")
  ' 2>/dev/null || true)"
  if [[ -n "${combined}" ]]; then
    ASSIGNMENTS_COLORS="$(printf '%s' "${combined}" | cut -d $'\x1f' -f1 2>/dev/null || true)"
    ASSIGNMENTS_ROWS="$(printf '%s' "${combined}" | cut -d $'\x1f' -f2- 2>/dev/null || true)"
    ASSIGNMENTS_COUNT="$(wc -l <<< "${ASSIGNMENTS_ROWS}" 2>/dev/null || echo 0)"
    ASSIGNMENTS_COUNT="${ASSIGNMENTS_COUNT//[^0-9]/}"
  fi
}

# 拉取并缓存（不渲染）。成功 0，失败置 BUPTY_ERR 且保留旧数据。
assignments_fetch() {
  # 账号切换时先清空旧账号数据，避免跨账号残留泄漏。
  if [[ "${ASSIGNMENTS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
    ASSIGNMENTS_DATA=""
    ASSIGNMENTS_ROWS=""
    ASSIGNMENTS_COLORS=""
    ASSIGNMENTS_COUNT=0
    ASSIGNMENTS_SEL=0
    ASSIGNMENTS_OFFSET=0
  fi
  # 用临时文件承接 stdout，避免 $(...) 子 shell 丢失 BUPTY_ERR / 会话副作用。
  local tmp data
  tmp="$(mktemp)"
  if ucloud_fetch_assignments > "${tmp}"; then
    data="$(cat "${tmp}")"
    rm -f "${tmp}"
    ASSIGNMENTS_DATA="${data}"
    ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
    ASSIGNMENTS_LOADED=1
    ASSIGNMENTS_SEL=0
    ASSIGNMENTS_OFFSET=0
    _assignments_precompute
    return 0
  fi
  rm -f "${tmp}"
  ASSIGNMENTS_LOADED=1
  ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
  return 1
}

# 刷新（r 键）：先渲染「加载中」，再拉取，再重渲染。
assignments_refresh() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  tui_set_status "正在加载作业…"
  tui_render
  if ! assignments_fetch; then
    return 1
  fi
  local n
  n="$(_assignments_count)"
  tui_set_status "已加载 ${n} 项作业。"
  tui_render
  return 0
}

# 渲染单行：截止日期 + 剩余天数 + 课程名 + 作业标题 + 状态。
_assignments_render_row() {
  local i="$1"
  local line="${_ASSIGNMENTS_ROWS[$i]:-}"
  [[ -z "${line}" ]] && return 0
  local deadline_disp days_disp course title status color raw
  IFS=$'\x1f' read -r deadline_disp days_disp course title status <<< "${line}"
  color="${_ASSIGNMENTS_COLORS[$i]:-text}"

  local title_w=$((UI_COLS - 58))
  if (( title_w < 8 )); then title_w=8; fi

  raw="$(printf '%s %s %s %s %s' \
    "$(core_fit "${deadline_disp}" 16)" \
    "$(core_fit "${days_disp}" 11)" \
    "$(core_fit "${course}" 16)" \
    "$(core_fit "${title}" "${title_w}")" \
    "${status}")"

  if [[ "${i}" -eq "${ASSIGNMENTS_SEL}" ]]; then
    printf ' %s%s%s\n' "${UI_HL}" "$(core_fit "${raw}" "$((UI_COLS - 4))")" "${UI_RESET}"
  else
    printf '  %s\n' "$(ui_paint "${color}" "${raw}")"
  fi
}

# 渲染列表主体（含顶部账号/总数信息行）。
_assignments_render_list() {
  local total
  total="$(_assignments_count)"
  printf '\n'
  printf ' %s\n' "$(ui_paint muted "账号 ${BUPTY_ACCOUNT} · 共 ${total} 项作业 · ↑↓ 选择 · s/Enter 提交 · r 刷新")"

  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    if [[ -n "${BUPTY_ERR}" ]]; then
      printf '\n %s\n' "$(ui_paint danger '  加载失败，请查看底部错误信息。')"
    else
      printf '\n %s\n' "$(ui_paint muted '  暂无作业')"
    fi
    return 0
  fi

  if (( total == 0 )); then
    printf '\n %s\n' "$(ui_paint muted '  暂无作业')"
    return 0
  fi

  # 每帧两次 readarray 纯 bash 读入，渲染循环内不再有任何 jq。
  _ASSIGNMENTS_ROWS=()
  _ASSIGNMENTS_COLORS=()
  if [[ -n "${ASSIGNMENTS_ROWS}" ]]; then
    readarray -t _ASSIGNMENTS_ROWS <<< "${ASSIGNMENTS_ROWS}"
  fi
  if [[ -n "${ASSIGNMENTS_COLORS}" ]]; then
    readarray -t _ASSIGNMENTS_COLORS <<< "${ASSIGNMENTS_COLORS}"
  fi

  local visible=$((UI_ROWS - 8))
  if (( visible < 5 )); then visible=5; fi
  if (( ASSIGNMENTS_SEL >= total )); then ASSIGNMENTS_SEL=$((total - 1)); fi
  if (( ASSIGNMENTS_SEL < 0 )); then ASSIGNMENTS_SEL=0; fi
  local offset="${ASSIGNMENTS_OFFSET:-0}"
  if (( ASSIGNMENTS_SEL < offset )); then offset=${ASSIGNMENTS_SEL}; fi
  if (( ASSIGNMENTS_SEL >= offset + visible )); then offset=$((ASSIGNMENTS_SEL - visible + 1)); fi
  ASSIGNMENTS_OFFSET=${offset}
  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  local i
  for ((i = offset; i < end; i++)); do
    _assignments_render_row "${i}"
  done
}

# 进入视图渲染。首次进入同步拉取（短暂阻塞），随后渲染列表或错误。
render_assignments() {
  if ! creds_load; then
    printf '\n %s\n' "$(ui_paint muted '  请先在设置中登录。')"
    return 0
  fi
  if _assignments_stale; then
    if [[ -z "${TUI_FETCH_PID}" ]]; then
      # 账号切换时先清空旧数据，再后台拉取。
      if [[ "${ASSIGNMENTS_ACCOUNT}" != "${BUPTY_ACCOUNT}" ]]; then
        ASSIGNMENTS_DATA=""; ASSIGNMENTS_ROWS=""; ASSIGNMENTS_COLORS=""; ASSIGNMENTS_COUNT=0
        ASSIGNMENTS_SEL=0; ASSIGNMENTS_OFFSET=0
      fi
      _async_start assignments ucloud_fetch_assignments
    fi
  fi
  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    printf '\n %s\n' "$(ui_paint muted '  正在加载作业…')"
  else
    _assignments_render_list
  fi
}

# 后台拉取完成回调：读取数据并更新视图状态。
apply_assignments() {
  local file="$1" data
  data="$(cat "${file}" 2>/dev/null || true)"
  if [[ "${data}" == ERROR:* ]]; then
    core_err "${data#ERROR:}"
    ASSIGNMENTS_LOADED=1
    ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
    return 0
  fi
  if [[ -n "${data}" ]]; then
    ASSIGNMENTS_DATA="${data}"
    ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
    ASSIGNMENTS_LOADED=1
    ASSIGNMENTS_SEL=0
    ASSIGNMENTS_OFFSET=0
    _assignments_precompute
  else
    core_err "加载失败。"
    ASSIGNMENTS_LOADED=1
    ASSIGNMENTS_ACCOUNT="${BUPTY_ACCOUNT}"
  fi
  return 0
}

# 当前选中作业（JSON 对象）。无数据/越界返回 1。
_assignments_selected() {
  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    return 1
  fi
  local obj
  obj="$(printf '%s' "${ASSIGNMENTS_DATA}" | jq -c --argjson i "${ASSIGNMENTS_SEL}" '.[$i] // empty' 2>/dev/null || true)"
  if [[ -z "${obj}" ]]; then
    return 1
  fi
  printf '%s' "${obj}"
}

# 提交成功后本地把当前作业标记为已提交（列表即时反馈）。
_assignments_mark_submitted() {
  if [[ -z "${ASSIGNMENTS_DATA}" ]]; then
    return 0
  fi
  ASSIGNMENTS_DATA="$(printf '%s' "${ASSIGNMENTS_DATA}" | jq -c --argjson i "${ASSIGNMENTS_SEL}" \
    'if (.[$i] // null) != null then .[$i].status = "已提交" else . end' 2>/dev/null || true)"
  _assignments_precompute
}

# 提交流程：同步、逐步交互，Esc 任一步可安全取消。
# 显示作业提交说明（多行、彩色、有层次；行宽随终端自适应截断）。
_submit_show_instructions() {
  local target="$1" i ext_w desc_w
  local -a cats=("音频" "视频" "图片" "文档" "PPT" "压缩包")
  local -a exts=("mp3、m4a" "mp4" "jpg、gif、png、jpeg" "txt、doc、docx、pdf、xls、xlsx" "ppt、pptx" "rar、zip")
  local -a sizes=("100MB" "200MB" "20MB" "100MB" "300MB" "3GB")
  # 扩展名+大小 列的可用宽度（前缀 "    · 分类 " 约 12 列 + 余量）。
  ext_w=$((UI_COLS - 16))
  (( ext_w < 8 )) && ext_w=8
  desc_w=$((UI_COLS - 8))
  (( desc_w < 10 )) && desc_w=10

  printf ' %s\n' "$(ui_paint title '作业提交')"
  printf ' %s\n' "$(ui_paint muted "  $(core_fit "${target}" "$((UI_COLS - 4))")")"
  printf '\n'
  printf ' %s\n' "$(ui_paint accent '附件约束')"
  printf ' %s\n' "$(ui_paint warning '  最多 10 个附件')"
  for ((i = 0; i < 6; i++)); do
    printf '    · %s %s\n' \
      "$(ui_paint text "$(core_fit "${cats[$i]}" 6)")" \
      "$(ui_paint muted "$(core_fit "${exts[$i]}  ≤ ${sizes[$i]}" "${ext_w}")")"
  done
  printf '\n'
  printf ' %s\n' "$(ui_paint accent '提交方式说明')"
  printf ' %s\n' "$(ui_paint text '  指定文件夹')"
  printf ' %s\n' "$(ui_paint muted "      $(core_fit 'homework_content.txt 作为作业内容文字；其余合规文件作为附件' "${desc_w}")")"
  printf ' %s\n' "$(ui_paint text '  指定单个文件')"
  printf ' %s\n' "$(ui_paint muted "      $(core_fit '该文件作为唯一附件（无内容文字）' "${desc_w}")")"
  printf '\n'
}

_assignments_submit_flow() {
  local obj id title course deadline status
  if ! obj="$(_assignments_selected)"; then
    core_err "暂无作业可提交。"
    return 1
  fi
  id="$(printf '%s' "${obj}" | jq -r '.id // empty' 2>/dev/null || true)"
  title="$(printf '%s' "${obj}" | jq -r '.title // "未命名作业"' 2>/dev/null || true)"
  course="$(printf '%s' "${obj}" | jq -r '.course_name // ""' 2>/dev/null || true)"
  deadline="$(printf '%s' "${obj}" | jq -r '.deadline // ""' 2>/dev/null || true)"
  status="$(printf '%s' "${obj}" | jq -r '.status // ""' 2>/dev/null || true)"
  if core_is_blank "${id}"; then
    core_err "作业信息不完整，无法提交。"
    return 1
  fi

  # 清屏展示提交对话框（说明用多行彩色，避免单行长文本换行/重复）。
  ui_clear
  tui_render_header
  local target=""
  target="【${course}】${title}"
  [[ -n "${deadline}" ]] && target+="（截止 ${deadline}）"
  [[ -n "${status}" ]] && target+="（${status}）"
  _submit_show_instructions "${target}"

  # 选择提交方式（方向键高亮选择，与全 app 一致）。
  printf ' %s\n' "$(ui_paint muted '提交方式（↑↓ 选择 · Enter 确认 · Esc 取消）')"
  local method
  if ! ui_select_option '1|指定文件夹' '2|指定单个文件'; then
    core_err "已取消提交。"
    return 1
  fi
  method="${UI_SELECT_RESULT}"

  # 选择路径。
  local path=""
  if [[ "${method}" == "1" ]]; then
    path="$(ui_select_directory "选择作业文件夹")"
  else
    path="$(ui_select_file "选择作业文件")"
  fi
  if core_is_blank "${path}"; then
    core_err "已取消提交。"
    return 1
  fi

  # 编排（认证/校验/确认/上传/提交在 lib/submit.sh）。
  if submit_do "${id}" "${method}" "${path}"; then
    tui_set_status "提交成功：${SUBMIT_MSG}"
    _assignments_mark_submitted
    return 0
  fi
  core_err "${BUPTY_ERR:-提交失败。}"
  return 1
}

# 按键处理：↑/↓ 移动、PgUp/PgDn 翻页、r 刷新。
handle_assignments_key() {
  local key="$1"
  local total
  case "${key}" in
    UP)
      if (( ASSIGNMENTS_SEL > 0 )); then ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL - 1)); fi
      ;;
    DOWN)
      total="$(_assignments_count)"
      if (( total > 0 && ASSIGNMENTS_SEL < total - 1 )); then ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL + 1)); fi
      ;;
    PGUP)
      ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL - 10))
      if (( ASSIGNMENTS_SEL < 0 )); then ASSIGNMENTS_SEL=0; fi
      ;;
    PGDN)
      total="$(_assignments_count)"
      ASSIGNMENTS_SEL=$((ASSIGNMENTS_SEL + 10))
      if (( total > 0 && ASSIGNMENTS_SEL >= total )); then ASSIGNMENTS_SEL=$((total - 1)); fi
      if (( ASSIGNMENTS_SEL < 0 )); then ASSIGNMENTS_SEL=0; fi
      ;;
    r)
      assignments_refresh
      ;;
    s|ENTER)
      _assignments_submit_flow || true
      ;;
  esac
}
