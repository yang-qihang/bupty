#!/usr/bin/env bash
# background.sh —— 后台守护：拉取作业，对「紧急 DDL」弹窗通知，防重复打扰。
# 由 bin/bupty --background 调用，不进入 TUI。

if [[ -n "${_BUPTY_BACKGROUND_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_BACKGROUND_LOADED=1

# 内存中的通知去重状态（id -> 截止日期 YYYY-MM-DD）。
BUPTY_NOTIFIED_JSON="{}"

# 日志到 stderr（守护进程标准做法，绝不打印凭据）。
_bg_log() {
  printf '[bupty-background] %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# 弹窗通知：优先 notify-send（libnotify/DBus，KDE/GNOME 等通用），
# 回退 zenity --notification / kdialog，都没有则 stderr 提示并跳过。
# ---------------------------------------------------------------------------
notify_send() {
  local title="$1" body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a bupty -u normal "${title}" "${body}" 2>/dev/null && return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    timeout 5 zenity --notification --text="${title}：${body}" 2>/dev/null && return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then
    timeout 5 kdialog --passivepopup "${body}" --title "${title}" 2>/dev/null && return 0
  fi
  _bg_log "未找到 notify-send/zenity/kdialog，已跳过通知。"
  return 1
}

# ---------------------------------------------------------------------------
# 通知去重状态（notified.json）
# ---------------------------------------------------------------------------

notified_load() {
  local f="${BUPTY_NOTIFIED_FILE}"
  if [[ -f "${f}" && ! -L "${f}" ]]; then
    BUPTY_NOTIFIED_JSON="$(cat "${f}" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)" \
      || BUPTY_NOTIFIED_JSON="{}"
  else
    BUPTY_NOTIFIED_JSON="{}"
  fi
}

notified_save() {
  core_ensure_dirs
  local tmp
  tmp="$(mktemp "${BUPTY_CONFIG_DIR}/.notified.XXXXXX")"
  printf '%s\n' "${BUPTY_NOTIFIED_JSON}" > "${tmp}"
  mv -f "${tmp}" "${BUPTY_NOTIFIED_FILE}"
}

# 该作业（id + 截止日期）是否已通知过。
notified_has() {
  local id="$1" date="$2"
  notified_load
  [[ "$(printf '%s' "${BUPTY_NOTIFIED_JSON}" | jq -r --arg k "${id}" '.[$k] // empty' 2>/dev/null)" == "${date}" ]]
}

# 记录已通知。失败时保留旧状态（避免清空导致重复轰炸）。
notified_mark() {
  local id="$1" date="$2"
  notified_load
  local new
  new="$(printf '%s' "${BUPTY_NOTIFIED_JSON}" | jq -c --arg k "${id}" --arg v "${date}" \
    '.[$k] = $v' 2>/dev/null)" || { _bg_log "通知状态更新失败，跳过。"; return 1; }
  BUPTY_NOTIFIED_JSON="${new}"
  notified_save
}

# 清理：只保留仍「紧急」的作业，并同步最新截止日期（已提交/已截止的自动移除）。
notified_prune() {
  local urgent_json="$1"
  notified_load
  local new
  new="$(jq -cn --argjson n "${BUPTY_NOTIFIED_JSON}" --argjson u "${urgent_json}" \
    '$n | with_entries(select($u[.key] != null)) | with_entries(.value = $u[.key])' 2>/dev/null)" \
    || { _bg_log "通知状态清理失败，跳过。"; return 1; }
  BUPTY_NOTIFIED_JSON="${new}"
  notified_save
}

# ---------------------------------------------------------------------------
# 紧急 DDL 判定与单轮检查
# ---------------------------------------------------------------------------

# 从作业数组筛出「紧急」项：未提交，且截止日期在 [今天, 今天+3天]。
background_urgent_filter() {
  local assignments="$1" today="${2:-$(core_today)}"
  local today3
  today3="$(TZ=Asia/Shanghai date -d "${today} + 3 days" +%Y-%m-%d 2>/dev/null || date -d "${today} + 3 days" +%Y-%m-%d)"
  printf '%s' "${assignments}" | jq -c --arg t0 "${today}" --arg t3 "${today3}" '
    [.[] | select(.status == "未提交")
         | select((((.deadline // "") | .[0:10]) >= $t0))
         | select((((.deadline // "") | .[0:10]) <= $t3))]
  ' 2>/dev/null || printf '[]'
}

# 单轮：拉作业 → 筛紧急 → 逐条通知（去重）→ 清理状态。失败不致命（返回非 0）。
background_check_once() {
  local assignments today urgent urgent_map tmp
  # 在当前 shell 内运行（重定向而非命令替换），保留 BUPTY_ERR 与会话状态。
  tmp="$(mktemp)"
  if ! ucloud_fetch_assignments > "${tmp}"; then
    rm -f "${tmp}"
    _bg_log "拉取作业失败：${BUPTY_ERR:-未知错误}"
    return 1
  fi
  assignments="$(cat "${tmp}")"
  rm -f "${tmp}"
  [[ -n "${assignments}" ]] || assignments="[]"
  today="$(core_today)"
  urgent="$(background_urgent_filter "${assignments}" "${today}")"
  urgent_map="$(printf '%s' "${urgent}" | jq -c \
    'map({key: .id, value: ((.deadline // "") | .[0:10])}) | from_entries' 2>/dev/null)" || urgent_map="{}"

  local line id title course deadline days when label body
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    id="$(printf '%s' "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
    [[ -n "${id}" ]] || continue
    deadline="$(printf '%s' "${line}" | jq -r '.deadline // empty' 2>/dev/null || true)"
    notified_has "${id}" "${deadline:0:10}" && continue
    title="$(printf '%s' "${line}" | jq -r '.title // empty' 2>/dev/null || true)"
    course="$(printf '%s' "${line}" | jq -r '.course_name // empty' 2>/dev/null || true)"
    days="$(core_days_between "${deadline:0:10}" "${today}")"
    if [[ "${days}" == "0" ]]; then
      when="今天截止"
    else
      when="剩 ${days} 天"
    fi
    if [[ -n "${course}" ]]; then
      label="《${course}》${title}"
    else
      label="${title}"
    fi
    body="${label} · ${when}（${deadline:0:16}）"
    if notify_send "作业即将截止" "${body}"; then
      notified_mark "${id}" "${deadline:0:10}"
    fi
  done < <(printf '%s' "${urgent}" | jq -c '.[]' 2>/dev/null)
  notified_prune "${urgent_map}"
  return 0
}

# 按分钟睡眠，但每秒检查一次停止标志，便于 SIGTERM/SIGINT 优雅退出。
_background_sleep_minutes() {
  local mins="$1" total i
  [[ "${mins}" =~ ^[0-9]+$ ]] || mins=60
  (( mins < 1 )) && mins=1
  total=$(( mins * 60 ))
  for ((i = 0; i < total; i++)); do
    [[ "${_bg_running:-1}" -eq 1 ]] || return 1
    sleep 1
  done
  return 0
}

# 后台主循环。返回 0 正常退出（无凭据/未开启/收到信号）。
background_run() {
  # 单实例锁：防止多个守护重复弹窗。
  core_ensure_dirs
  local lockfile
  lockfile="${BUPTY_CONFIG_DIR}/background.lock"
  exec 9>"${lockfile}"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
      _bg_log "已有后台实例运行，退出。"
      return 0
    fi
  fi

  if ! creds_load; then
    _bg_log "未找到凭据，后台模式退出。"
    return 0
  fi
  if [[ "$(settings_get notify_enabled)" != "true" || "$(settings_get autostart_enabled)" != "true" ]]; then
    _bg_log "紧急 DDL 通知或自启动未开启，后台模式退出。"
    return 0
  fi

  local _bg_running=1
  trap '_bg_running=0' TERM INT HUP

  # 循环体容错：任何失败只记录并进入下一轮，绝不退出。
  set +e
  local interval
  while [[ "${_bg_running}" -eq 1 ]]; do
    background_check_once
    interval="$(settings_get notify_interval)"
    if ! [[ "${interval}" =~ ^[0-9]+$ ]]; then
      interval=60
    fi
    _background_sleep_minutes "${interval}" || break
  done
  set -e
  return 0
}
