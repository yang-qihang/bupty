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

# ===========================================================================
# 8. 设置页视图：登出分支 + 主题选择器（本轮暴露的最大覆盖空洞）
# ===========================================================================
# 登出：修复前 handle_settings_key 的 logout 分支调用拼错的 creds_clea（少一个字符），
# 后果是**凭据文件根本没被删**、状态栏却报「已清除本地凭据。」、返回码还是 0。
# 修掉前后 unit_settings.sh 都是「36 通过 0 失败」——整个登出行为**零覆盖**。
# 这一节驱动真实设置页处理函数，断言文件系统事实（文件真的没了）+ 状态栏不说谎。
#
# 载入整套 tui.sh 以拿到真实的 handle_settings_key / _settings_picker_* /
# footer_hint_settings / tui_render_footer（与生产同一份代码，不是复刻）。
# tui.sh 自己 set -euo pipefail，载入后立刻关掉 errexit（与其它测试同一约定）。
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tui.sh"
set +e

# 只为下面两节服务的假凭据（**绝不含真实账号/口令，也绝不打印口令**）。
SETTINGS_FAKE_ACCOUNT="2021999999"
SETTINGS_FAKE_PASSWORD="not-a-real-password"

# 某键在 SETTINGS_ITEMS 里的下标（不写死数字：条目顺序一变，写死的断言会静默错位）。
_settings_item_index() {
  local want="$1" i key
  for i in "${!SETTINGS_ITEMS[@]}"; do
    IFS='|' read -r key _ <<< "${SETTINGS_ITEMS[$i]}"
    [[ "${key}" == "${want}" ]] && { printf '%s' "${i}"; return 0; }
  done
  printf '%s' "-1"
}

# 字符串是否含子串（子串按字面匹配，不解释 glob）。
s_has() { [[ "${1:-}" == *"$2"* ]]; }

t_begin "登出：凭据文件必须真的被删除且状态栏不说谎"
rm -f "${BUPTY_CREDENTIALS_FILE}"
# 反向对照：先确认「存在」这条能被测到，再谈「不存在」。
assert_fail test -e "${BUPTY_CREDENTIALS_FILE}"
assert_ok creds_save "${SETTINGS_FAKE_ACCOUNT}" "${SETTINGS_FAKE_PASSWORD}"
assert_ok test -f "${BUPTY_CREDENTIALS_FILE}"
# 凭据文件内容确实是假账号（不打印口令，只看账号字段）。
assert_eq "$(jq -r '.account' "${BUPTY_CREDENTIALS_FILE}")" "${SETTINGS_FAKE_ACCOUNT}" \
  "写入的应是假账号（证明读取的是本次造的凭据，不是真实文件）"

SETTINGS_SEL="$(_settings_item_index logout)"
assert_ok test "${SETTINGS_SEL}" -ge 0
SETTINGS_PASSWORD="非空缓冲"
SETTINGS_TEACHING="非空缓冲"
TUI_STATUS=""
handle_settings_key ENTER
# 核心：文件必须真的不存在了（拼错函数名时它还在）。
assert_fail test -e "${BUPTY_CREDENTIALS_FILE}"
assert_fail test -L "${BUPTY_CREDENTIALS_FILE}"
# 状态栏文案必须与实际一致。
assert_eq "${TUI_STATUS}" "已清除本地凭据。" "状态栏提示必须与实际行为一致"
# 内存副作用：账号/编辑缓冲都得清空，且 creds_load 读不回来。
assert_eq "${BUPTY_ACCOUNT}" "" "内存账号应已清空"
assert_eq "${SETTINGS_PASSWORD}" "" "密码编辑缓冲应已清空"
assert_eq "${SETTINGS_TEACHING}" "" "教学云密码缓冲应已清空"
assert_fail creds_load

# 选择器：打开时游标停在当前**已应用**主题，并记下 ORIG 供 Esc 还原。
t_begin "选择器：打开时游标停在当前已应用主题"
ui_theme_init "latte"
SETTINGS_SEL="$(_settings_item_index theme)"
assert_ok test "${SETTINGS_SEL}" -ge 0
handle_settings_key ENTER            # 真实路径：theme 行 Enter → _settings_picker_open
assert_eq "${SETTINGS_PICKER}" "1" "theme 行 Enter 应打开选择器"
assert_eq "${SETTINGS_PICKER_SEL}" "$(ui_theme_index latte)" "游标应停在当前已应用主题 latte"
assert_eq "${SETTINGS_PICKER_ORIG}" "latte" "应记下进入时的主题用于 Esc 还原"

# ↑↓ 实时预览 + 到顶/到底不循环。
t_begin "选择器：UP/DOWN 实时预览且到顶/到底不循环"
SETTINGS_PICKER_SEL=0
ui_theme_init "${UI_THEME_NAMES[0]}"
handle_settings_key UP
assert_eq "${SETTINGS_PICKER_SEL}" "0" "顶部再按 UP 不循环"
handle_settings_key DOWN
assert_eq "${SETTINGS_PICKER_SEL}" "1" "DOWN 前进一格"
assert_eq "${UI_THEME}" "${UI_THEME_NAMES[1]}" "DOWN 后实时预览到 1 号主题（不落盘）"
s_last=$(( ${#UI_THEME_NAMES[@]} - 1 ))
SETTINGS_PICKER_SEL="${s_last}"
ui_theme_init "${UI_THEME_NAMES[$s_last]}"
handle_settings_key DOWN
assert_eq "${SETTINGS_PICKER_SEL}" "${s_last}" "底部再按 DOWN 不循环"
assert_eq "${UI_THEME}" "${UI_THEME_NAMES[$s_last]}" "到底 DOWN 不得改预览主题"

# 页脚提示随开/关切换（钩子 + 真的接进 tui_render_footer）。
t_begin "选择器：页脚提示随开/关切换"
SETTINGS_PICKER=0
assert_eq "$(footer_hint_settings)" "" "关闭时覆盖点输出空串（落回默认提示）"
SETTINGS_PICKER=1
assert_eq "$(footer_hint_settings)" "↑↓ 选择 · Enter 保存 · Esc 撤销 · q 退出" \
  "打开时输出与选择器真实键位一致的提示"
TUI_VIEW=settings UI_COLS=100 TUI_STATUS=""
SETTINGS_PICKER=0; s_foot_off="$(tui_render_footer | tail -1)"
SETTINGS_PICKER=1; s_foot_on="$(tui_render_footer | tail -1)"
assert_eq "$([[ "${s_foot_on}"  == *"保存"* ]] && printf yes || printf no)" "yes" \
  "选择器打开时页脚确实出现「保存」"
assert_eq "$([[ "${s_foot_off}" == *"保存"* ]] && printf yes || printf no)" "no" \
  "关闭时页脚不得出现「保存」（否则「切换」是假的）"

# Enter 落盘（走真实 handle_settings_key ENTER 路径）。
t_begin "选择器：Enter 落盘"
ui_theme_init "dark"
settings_set theme dark
SETTINGS_PICKER=0                             # 从干净状态开始（上一节末尾停在打开态）
SETTINGS_SEL="$(_settings_item_index theme)"
handle_settings_key ENTER                     # 打开
SETTINGS_PICKER_SEL="$(ui_theme_index gruvbox)"
ui_theme_init gruvbox                         # 模拟实时预览已切到候选
handle_settings_key ENTER                     # 确认
assert_eq "${SETTINGS_PICKER}" "0" "Enter 后选择器关闭"
assert_eq "$(settings_get theme)" "gruvbox" "Enter 应把候选落盘"
assert_eq "${UI_THEME}" "gruvbox" "落盘后应用主题即候选"

# Esc 还原且不落盘（走真实 handle_settings_escape 路径）。
t_begin "选择器：Esc 还原且不落盘"
ui_theme_init "dark"
settings_set theme dark
SETTINGS_PICKER=0
SETTINGS_SEL="$(_settings_item_index theme)"
handle_settings_key ENTER                     # 打开（orig=dark）
handle_settings_key DOWN                      # 实时预览到 light，但不落盘
assert_eq "${UI_THEME}" "light" "DOWN 实时预览到 light"
assert_eq "$(settings_get theme)" "dark" "实时预览不得落盘"
handle_settings_escape
assert_eq "${SETTINGS_PICKER}" "0" "Esc 应关闭选择器"
assert_eq "${UI_THEME}" "dark" "Esc 应还原到进入时的主题"
assert_eq "$(settings_get theme)" "dark" "Esc 不得落盘"
# 选择器关闭时 handle_settings_escape 必须返回非 0（交回默认「返回上一页」）。
assert_fail handle_settings_escape

# settings_set 失败时回滚到 SETTINGS_PICKER_ORIG。
# 放在最后：这里会把 settings_set 覆盖成失败桩，末尾不再依赖真实落盘。
t_begin "选择器：settings_set 失败时回滚到 SETTINGS_PICKER_ORIG"
ui_theme_init "dark"
SETTINGS_PICKER_ORIG="dark"
SETTINGS_PICKER_SEL="$(ui_theme_index latte)"
ui_theme_init latte                           # 预览到 latte
TUI_STATUS=""
settings_set() { return 1; }                   # 注入落盘失败（测试进程内覆盖，不动产品代码）
_settings_picker_confirm
assert_eq "${UI_THEME}" "dark" "落盘失败应回滚到 ORIG（看到的重新等于存盘的）"
assert_eq "${SETTINGS_PICKER}" "0" "失败后仍应关闭选择器"
assert_eq "$([[ "${TUI_STATUS}" == *"还原"* ]] && printf yes || printf no)" "yes" \
  "状态栏应说明已还原，而不是留一个会漂移的状态"

t_summary
