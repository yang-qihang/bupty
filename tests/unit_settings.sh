#!/usr/bin/env bash
# tests/unit_settings.sh —— 持久化设置 / 自启动 / 后台通知判定与去重 单元测试（全离线）。
set -uo pipefail

# 隔离配置目录：设置 XDG_CONFIG_HOME 与 HOME 到临时目录，避免污染真实配置。
TMPROOT="$(mktemp -d)"
export XDG_CONFIG_HOME="${TMPROOT}/config"
export HOME="${TMPROOT}/home"
mkdir -p "${XDG_CONFIG_HOME}" "${HOME}"

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/settings.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/background.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# ---------------------------------------------------------------------------
# 1. 设置默认值
# ---------------------------------------------------------------------------
t_begin "设置默认值"
assert_eq "$(settings_get autostart_enabled)" "false" "默认关闭自启动"
assert_eq "$(settings_get notify_enabled)" "false" "默认关闭通知"
assert_eq "$(settings_get notify_interval)" "60" "默认 60 分钟"

# ---------------------------------------------------------------------------
# 2. 设置读写与持久化
# ---------------------------------------------------------------------------
t_begin "设置读写"
assert_ok settings_set notify_interval 30
assert_ok settings_set notify_enabled true
assert_ok settings_set autostart_enabled true
assert_eq "$(settings_get notify_interval)" "30" "间隔 30"
assert_eq "$(settings_get notify_enabled)" "true" "通知开"
assert_eq "$(settings_get autostart_enabled)" "true" "自启动开"

t_begin "设置重新从磁盘加载"
BUPTY_SETTINGS_JSON=""
assert_eq "$(settings_get notify_interval)" "30" "落盘后读回 30"
assert_eq "$(settings_get notify_enabled)" "true" "落盘后读回通知开"

# ---------------------------------------------------------------------------
# 3. 损坏 JSON 回退默认值
# ---------------------------------------------------------------------------
t_begin "损坏 JSON 回退默认值"
printf 'not-json{{{' > "${BUPTY_SETTINGS_FILE}"
BUPTY_SETTINGS_JSON=""
assert_fail settings_load
assert_eq "$(settings_get autostart_enabled)" "false" "损坏后回退默认 false"
assert_eq "$(settings_get notify_interval)" "60" "损坏后回退默认 60"

# ---------------------------------------------------------------------------
# 4. 开机自启动（.desktop 写入 / 删除）
# ---------------------------------------------------------------------------
t_begin "开机自启动启用"
assert_ok autostart_enable
assert_ok test -f "${BUPTY_AUTOSTART_FILE}"
assert_ok grep -q '^Type=Application$' "${BUPTY_AUTOSTART_FILE}"
assert_ok grep -q '^Exec=.*--background$' "${BUPTY_AUTOSTART_FILE}"
assert_ok grep -q '^X-GNOME-Autostart-enabled=true$' "${BUPTY_AUTOSTART_FILE}"
assert_ok grep -q '^Terminal=false$' "${BUPTY_AUTOSTART_FILE}"
assert_ok autostart_is_enabled
assert_eq "$(settings_get autostart_enabled)" "true" "自启动标志应为 true"

t_begin "开机自启动禁用"
assert_ok autostart_disable
assert_fail test -e "${BUPTY_AUTOSTART_FILE}"
assert_fail autostart_is_enabled
assert_eq "$(settings_get autostart_enabled)" "false" "自启动标志应为 false"

# ---------------------------------------------------------------------------
# 5. 紧急 DDL 判定（未截止 + 0..3 天内 + 未提交）
# ---------------------------------------------------------------------------
t_begin "紧急 DDL 判定"
today="$(core_today)"
today1="$(date -d "${today} + 1 days" +%Y-%m-%d)"
today4="$(date -d "${today} + 4 days" +%Y-%m-%d)"
yesterday="$(date -d "${today} - 1 days" +%Y-%m-%d)"
arr="$(jq -cn --arg t0 "${today}" --arg t1 "${today1}" --arg t4 "${today4}" --arg y "${yesterday}" '
  [
    {id:"a", title:"今天截止", status:"未提交", deadline:($t0+" 23:59:00")},
    {id:"b", title:"3天内", status:"未提交", deadline:($t1+" 12:00:00")},
    {id:"c", title:"已提交", status:"已提交", deadline:($t0+" 10:00:00")},
    {id:"d", title:"超3天", status:"未提交", deadline:($t4+" 00:00:00")},
    {id:"e", title:"已截止", status:"未提交", deadline:($y+" 00:00:00")},
    {id:"f", title:"已批改", status:"已批改", deadline:($t1+" 00:00:00")}
  ]')"
urgent="$(background_urgent_filter "${arr}" "${today}")"
assert_eq "$(printf '%s' "${urgent}" | jq -r 'map(.id) | join(",")')" "a,b" "仅未提交且 0..3 天内"

# ---------------------------------------------------------------------------
# 6. 通知去重与清理
# ---------------------------------------------------------------------------
t_begin "通知去重与清理"
rm -f "${BUPTY_NOTIFIED_FILE}"
assert_fail notified_has "a" "${today}"
notified_mark "a" "${today}"
assert_ok notified_has "a" "${today}"
assert_fail notified_has "a" "${today1}" "截止日期变了应视为未通知"
# 清理：只保留仍紧急的 id，并同步最新截止日期；已提交/已截止的移除。
notified_prune "$(jq -cn --arg a "${today1}" '{"a":$a,"x":"2020-01-01"}')"
assert_ok notified_has "a" "${today1}"
assert_fail notified_has "a" "${today}" "旧日期应被更新"
assert_fail notified_has "x" "2020-01-01" "非已通知 id 不保留"

# ---------------------------------------------------------------------------
# 7. 弹窗通知器选择
# ---------------------------------------------------------------------------
t_begin "notify_send 优先使用 notify-send"
stubdir="$(mktemp -d)"
cat > "${stubdir}/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STUB_OUT}"
exit 0
EOF
chmod +x "${stubdir}/notify-send"
export STUB_OUT="$(mktemp)"
saved_path="${PATH}"
PATH="${stubdir}:${saved_path}"
notify_send "标题T" "正文B" || true
PATH="${saved_path}"
assert_ok grep -q -- "-a bupty -u normal 标题T 正文B" "${STUB_OUT}"

t_begin "notify_send 回退 zenity"
stubdir2="$(mktemp -d)"
# notify-send 存在但失败（如无 DBus 会话），应回退到 zenity。
cat > "${stubdir2}/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${stubdir2}/notify-send"
cat > "${stubdir2}/zenity" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STUB_OUT}"
exit 0
EOF
chmod +x "${stubdir2}/zenity"
export STUB_OUT="$(mktemp)"
saved_path="${PATH}"
PATH="${stubdir2}:${saved_path}"
notify_send "标题T" "正文B" || true
PATH="${saved_path}"
assert_ok grep -q -- "--notification" "${STUB_OUT}"

t_begin "notify_send 无可用通知器时跳过"
saved_path="${PATH}"
PATH="$(mktemp -d)"
rc=0
notify_send "标题T" "正文B" 2>/dev/null || rc=$?
PATH="${saved_path}"
assert_eq "${rc}" "1" "应返回 1"

t_summary
