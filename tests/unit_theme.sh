#!/usr/bin/env bash
# tests/unit_theme.sh —— 主题系统单元测试（全离线、无网络）。
#
# 覆盖 GitHub issue #2 第一条要求：多套具名配色（至少一套浅色）、用户可选、可持久化。
# 断言要点：
#   1. 每套主题的 12 个角色变量都非空（最容易漏角色——漏一个就会出现无色/串色行）
#   2. 主题名清单 / 设置页候选 / ui_theme_init 的分派三者一致（无「列了切不过去」，
#      也无「能切但没列」）
#   3. 未知主题名有安全兜底：不崩、不留空变量、退回默认主题
#   4. settings.json 里 theme 能往返，写入未知主题名被拒绝
#   5. 持久化后新起一个 shell 能读回（模拟重启后主题仍在）
#   6. 设置页渲染任何一行都不超过 UI_COLS（含新增的配色方案行）
#   7. 断言自检（负向对照）：故意造「角色为空」「主题名不在候选列表」，确认断言真的会
#      记失败——否则前面那一堆通过可能只是「什么都没测到」
set -uo pipefail

# 隔离配置目录：不污染真实配置；并清掉可能影响优先级判定的环境变量。
TMPROOT="$(mktemp -d)"
export XDG_CONFIG_HOME="${TMPROOT}/config"
export HOME="${TMPROOT}/home"
mkdir -p "${XDG_CONFIG_HOME}" "${HOME}"
unset BUPTY_THEME

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/settings.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/ui.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 12 个角色（必须全部由每套主题定义）。UI_SEL 是「选中前景·无背景」，
# 首页选中卡片文本区用它，不能退回带背景的 UI_HL_FG。
THEME_ROLES=(UI_ACCENT UI_TEXT UI_MUTED UI_BORDER UI_HL UI_HL_FG UI_SEL UI_SUCCESS UI_WARNING UI_DANGER UI_PURPLE UI_TITLE)

# 某角色变量非空（失败时点名主题 + 角色）。
assert_role_nonempty() {
  local theme="$1" role="$2"
  if [[ -n "${!role:-}" ]]; then
    ((TESTS_PASS += 1))
  else
    ((TESTS_FAIL += 1))
    printf 'FAIL [%s] 主题 %s 的角色 %s 为空\n' "${TESTS_NAME}" "${theme}" "${role}"
  fi
}

# 当前已应用主题的 12 个角色拼成的签名（用于证明两套主题确实不同）。
theme_signature() {
  local r out=""
  for r in "${THEME_ROLES[@]}"; do out+="${!r}|"; done
  printf '%s' "${out}"
}

# 剥 ANSI 转义，结果写全局 THEME_PLAIN。
# 必须用最短匹配逐个剥：`${s//$'\033'\[[0-9;]*[a-zA-Z]/}` 的 glob `*` 贪婪，
# 会一路吞到行尾，整行变空、宽度恒 0，测试会静默「全通过」。
theme_strip() {
  local s="${1:-}" out="" rest
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"
    s="${s#*$'\033['}"
    rest="${s#*[a-zA-Z]}"
    if [[ "${rest}" == "${s}" ]]; then
      s=""
      break
    fi
    s="${rest}"
  done
  THEME_PLAIN="${out}${s}"
}

# ===========================================================================
# 1. 主题清单完整性
# ===========================================================================
t_begin "主题清单"
assert_ok test "${#UI_THEME_NAMES[@]}" -ge 4
assert_eq "${#UI_THEME_LABELS[@]}" "${#UI_THEME_NAMES[@]}" "标签数应与主题数一一对应"
assert_ok ui_theme_valid light
# issue #2 的硬要求：至少一套浅色主题。直接查清单数据——早先这里断言的是
# _ui_is_dark（一个生产代码从不调用的判定函数），等于在测死代码。
dark_joined=" ${UI_THEME_DARK_NAMES[*]} "
assert_eq "$([[ "${dark_joined}" == *" light "* ]] && printf yes || printf no)" "no" \
  "light 不应出现在暗色清单里（必须有浅色主题）"
assert_ok ui_theme_valid dark
assert_fail ui_theme_valid no-such-theme

# 清单内无重复名。
dup=0
for i in "${!UI_THEME_NAMES[@]}"; do
  for j in "${!UI_THEME_NAMES[@]}"; do
    if (( i < j )) && [[ "${UI_THEME_NAMES[$i]}" == "${UI_THEME_NAMES[$j]}" ]]; then dup=1; fi
  done
done
assert_eq "${dup}" "0" "主题名不得重复"
# 每套主题都有非空中文标签。
for name in "${UI_THEME_NAMES[@]}"; do
  assert_ok test -n "$(ui_theme_label "${name}")"
done

# ===========================================================================
# 2. 每套主题：分派正确 + 11 角色齐全 + 与 dark 明显不同
# ===========================================================================
ui_theme_init dark
theme_dark_sig="$(theme_signature)"
assert_eq "${UI_THEME}" "dark" "默认应用 dark"

for name in "${UI_THEME_NAMES[@]}"; do
  t_begin "主题 ${name}"
  ui_theme_init "${name}"
  assert_eq "${UI_THEME}" "${name}" "ui_theme_init ${name} 后 UI_THEME 应等于 ${name}"
  for r in "${THEME_ROLES[@]}"; do
    assert_role_nonempty "${name}" "${r}"
  done
  # 非 dark 主题的调色板必须与 dark 不同（否则说明该分支不存在、落到了兜底）。
  if [[ "${name}" != "dark" ]]; then
    assert_ok test "$(theme_signature)" != "${theme_dark_sig}"
  fi
done

# ===========================================================================
# 3. 暗色清单与主题清单的关系
# ===========================================================================
# 早先这一节是拿 _ui_is_dark 跟 UI_THEME_DARK_NAMES 对比，而 _ui_is_dark 本身就是
# 遍历同一个数组实现的——恒真，永远失败不了。改成直接断言数据的性质。
t_begin "暗色清单"
# 暗色清单必须是主题清单的子集（否则设置页会列出不存在的主题）。
for d in "${UI_THEME_DARK_NAMES[@]}"; do
  assert_ok ui_theme_valid "${d}"
done
# 暗色清单不能覆盖全部主题，否则「至少一套浅色」不成立。
assert_ok test "${#UI_THEME_DARK_NAMES[@]}" -lt "${#UI_THEME_NAMES[@]}"
# 暗色清单内无重复。
dark_dup=0
for i in "${!UI_THEME_DARK_NAMES[@]}"; do
  for j in "${!UI_THEME_DARK_NAMES[@]}"; do
    if (( i != j )) && [[ "${UI_THEME_DARK_NAMES[$i]}" == "${UI_THEME_DARK_NAMES[$j]}" ]]; then
      dark_dup=1
    fi
  done
done
assert_eq "${dark_dup}" "0" "暗色清单内不应有重复主题名"

# ===========================================================================
# 4. 未知主题名安全兜底
# ===========================================================================
t_begin "未知主题名兜底"
ui_theme_init "no-such-theme"
assert_eq "${UI_THEME}" "${UI_THEME_DEFAULT}" "未知主题应退回默认"
for r in "${THEME_ROLES[@]}"; do
  assert_role_nonempty "unknown" "${r}"
done
BUPTY_THEME="bogus-env"
ui_theme_init
assert_eq "${UI_THEME}" "${UI_THEME_DEFAULT}" "未知环境变量主题应退回默认"
unset BUPTY_THEME

# ===========================================================================
# 5. settings.json 持久化往返 + 拒绝未知主题名
# ===========================================================================
t_begin "主题持久化往返"
assert_ok settings_set theme nord
assert_eq "$(settings_get theme)" "nord" "写入后可读出 nord"
BUPTY_SETTINGS_JSON=""
assert_eq "$(settings_get theme)" "nord" "从磁盘重新加载仍是 nord"

t_begin "拒绝未知主题名"
assert_fail settings_set theme "no-such-theme"
assert_eq "$(settings_get theme)" "nord" "被拒后已保存值不变"
assert_fail settings_set theme "Nord"   # 大小写敏感

t_begin "默认设置含 theme"
rm -f "${BUPTY_SETTINGS_FILE}"
BUPTY_SETTINGS_JSON=""
assert_eq "$(settings_get theme)" "dark" "默认主题应为 dark"

# 归一化白名单必须保留 theme 字段（漏改这里会在读取时被静默丢掉）。
t_begin "归一化白名单保留 theme"
printf '{"theme":"gruvbox"}' > "${BUPTY_SETTINGS_FILE}"
BUPTY_SETTINGS_JSON=""
assert_eq "$(settings_get theme)" "gruvbox" "旧文件里的 theme 应被保留"
assert_eq "$(settings_get autostart_enabled)" "false" "缺失字段应补默认"
printf '{"theme":123}' > "${BUPTY_SETTINGS_FILE}"
BUPTY_SETTINGS_JSON=""
assert_eq "$(settings_get theme)" "dark" "非字符串 theme 应归一为 dark"

# ===========================================================================
# 6. 优先级：BUPTY_THEME > settings.json > 默认
# ===========================================================================
t_begin "主题优先级"
assert_ok settings_set theme gruvbox
ui_theme_init                     # 无参、无环境变量 → 读 settings.json
assert_eq "${UI_THEME}" "gruvbox" "无环境变量时应读 settings.json"
BUPTY_THEME="light"
ui_theme_init
assert_eq "${UI_THEME}" "light" "BUPTY_THEME 应优先于 settings.json"
unset BUPTY_THEME
rm -f "${BUPTY_SETTINGS_FILE}"
BUPTY_SETTINGS_JSON=""
ui_theme_init
assert_eq "${UI_THEME}" "dark" "无设置文件时应退回默认 dark"

# ===========================================================================
# 7. 重启模拟：全新 shell 里 ui_theme_init 读回已保存主题
# ===========================================================================
t_begin "重启后主题仍在"
assert_ok settings_set theme gruvbox
new_shell="$(BUPTY_THEME= bash -c '
  source "$1/lib/core.sh"
  source "$1/lib/settings.sh"
  source "$1/lib/ui.sh"
  ui_theme_init
  printf "%s" "${UI_THEME}"
' _ "${BUPTY_HOME}")"
assert_eq "${new_shell}" "gruvbox" "新 shell 中 ui_theme_init 应读回已保存的 gruvbox"

# ===========================================================================
# 8. 候选列表循环与清单一致（设置页用 ui_theme_next/prev 切换）
# ===========================================================================
t_begin "候选列表循环一致"
cur="${UI_THEME_NAMES[0]}"
seen=()
for _ in "${UI_THEME_NAMES[@]}"; do
  seen+=("${cur}")
  cur="$(ui_theme_next "${cur}")"
done
assert_eq "${cur}" "${UI_THEME_NAMES[0]}" "next 循环应回到起点"
assert_eq "$(printf '%s,' "${seen[@]}")" "$(printf '%s,' "${UI_THEME_NAMES[@]}")" \
  "next 应恰好依次遍历全部主题（无重复、无遗漏）"
assert_eq "$(ui_theme_prev "${UI_THEME_NAMES[0]}")" "${UI_THEME_NAMES[-1]}" \
  "prev 从首项应回到末项"
for name in "${UI_THEME_NAMES[@]}"; do
  assert_ok ui_theme_valid "$(ui_theme_next "${name}")"
  assert_ok ui_theme_valid "$(ui_theme_prev "${name}")"
done

# ===========================================================================
# 9. 设置页渲染宽度：任何一行都不得超过 UI_COLS（含新增的配色方案行）
# ===========================================================================
# 负向对照：先证明「剥 ANSI 后量宽」确实生效——写的 strip 一旦贪婪吞到行尾，
# 宽度会恒为 0，下面所有宽度断言都会静默「通过」。
t_begin "strip 负向对照"
printf -v _colored '\033[38;5;244m\xE2\x96\xB8\033[0m\033[38;5;252m \xE4\xBD\x9C\xE4\xB8\x9A DDL\033[0m'
theme_strip "${_colored}"
_core_width "${THEME_PLAIN}"
assert_eq "${_CORE_W}" "10" "strip 后「▸ 作业 DDL」应量出 10 列（实际：${THEME_PLAIN}）"

# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/views/settings.sh"
assert_ok settings_set theme nord

# 负向对照：喂一条「必然超宽」的合成行给同一条测量链路，溢出判定必须报出来。
# 刻意不用 render_settings 造溢出——设置页的响应式正由另一位 agent 改，可能已经自行
# 裁剪，拿它当对照会随对方改动而失效；这里只验证「剥 ANSI → 量宽 → 比较」本身没坏。
t_begin "宽度检查器负向对照"
printf -v _wide '\033[38;5;39m\xE5\xAD\xA6\xE7\x94\x9F\xE4\xBF\xA1\xE6\x81\xAF\xE7\xAE\xA1\xE7\x90\x86\xE7\xB3\xBB\xE7\xBB\x9F\xE4\xB8\x8E\xE8\xAF\xBE\xE7\xA8\x8B\xE8\xA1\xA8\033[0m'
theme_strip "${_wide}"
_core_width "${THEME_PLAIN}"
narrow_w="${_CORE_W}"
assert_ok test "${narrow_w}" -gt 10
assert_eq "${narrow_w}" "24" "合成行「学生信息管理系统与课程表」应为 24 列（实际：${THEME_PLAIN}）"

t_begin "设置页宽度不超 UI_COLS"
settings_wide=0
for cols in 80 40; do
  # 选中行分别落在：账号(0)、教学云密码（最长标签，2）、配色方案（新枚举，3）。
  for sel in 0 2 3; do
    UI_COLS="${cols}"
    SETTINGS_SEL="${sel}"
    ui_theme_init nord
    lineno=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
      lineno=$((lineno + 1))
      theme_strip "${line}"
      _core_width "${THEME_PLAIN}"
      w="${_CORE_W}"
      if (( w > cols )); then
        settings_wide=$((settings_wide + 1))
        printf 'FAIL [%s] 第 %d 行宽 %d > UI_COLS=%d（sel=%s）：%q\n' \
          "${TESTS_NAME}" "${lineno}" "${w}" "${cols}" "${sel}" "${THEME_PLAIN}"
      fi
    done < <(render_settings)
  done
done
assert_eq "${settings_wide}" "0" "设置页任何一行都不得超过 UI_COLS"

# 配色方案行确实渲染出了候选值（不是空白）。
UI_COLS=80
SETTINGS_SEL=3
ui_theme_init nord
settings_out="$(render_settings)"
assert_ok grep -q "配色方案" <<< "${settings_out}"
assert_ok grep -q "Nord" <<< "${settings_out}"

# ===========================================================================
# 10. 断言自检（负向对照）：证明上面的断言真的「失败得出来」
# ===========================================================================
# 单靠「全绿」不能说明问题：如果断言函数本身写错（比如永远走通过分支），或者被测
# 对象恒为某个值，测试会静默全过却什么都没验证。下面专门构造必然失败/必然成功的
# 输入，确认断言函数把结果记进了 TESTS_FAIL / TESTS_PASS。
#
# 每个对照函数在返回前会把「故意制造的失败」从计数器里抹掉，所以故意造的失败不污染
# 总账；而自检本身的结论（对照是否成立）由外层 assert_ok 记入总账——这样自检一旦
# 失效，测试就会红，不会悄悄放过。对照函数内的 assert_* 输出都被 /dev/null 吞掉。
t_begin "断言自检（负向对照）"

# 10.1 角色为空时，检查函数必须判失败：造一个「漏定义 UI_MUTED」的假主题。
_neg_role_empty_fails() {
  local before="${TESTS_FAIL}" after saved="${UI_MUTED:-}"
  UI_MUTED=""                       # 空值正是「角色未定义」的失败条件
  assert_role_nonempty "fake-missing-muted" UI_MUTED
  after="${TESTS_FAIL}"
  UI_MUTED="${saved}"               # 复原，避免污染后续断言
  TESTS_FAIL="${before}"            # 抹掉这次「故意失败」，只让自检结论入账
  [[ "${after}" -gt "${before}" ]]
}
assert_ok _neg_role_empty_fails

# 10.2 反向：角色有值时不得误判失败（防止 10.1 恒成立而失去意义）。
_neg_role_present_passes() {
  local before="${TESTS_FAIL}" after
  assert_role_nonempty "fake-ok" UI_ACCENT
  after="${TESTS_FAIL}"
  [[ "${after}" -eq "${before}" ]]
}
assert_ok _neg_role_present_passes

# 10.3 主题名不在候选列表时，断言必须判失败。
_neg_name_unlisted_fails() {
  local before="${TESTS_FAIL}" after
  assert_ok ui_theme_valid "definitely-not-a-theme-xyz"
  after="${TESTS_FAIL}"
  TESTS_FAIL="${before}"            # 抹掉这次「故意失败」
  [[ "${after}" -gt "${before}" ]]
}
assert_ok _neg_name_unlisted_fails

# 10.4 反向：候选列表内的名称不得误判失败。
_neg_name_listed_passes() {
  local before="${TESTS_FAIL}" after
  assert_ok ui_theme_valid "${UI_THEME_DEFAULT}"
  after="${TESTS_FAIL}"
  [[ "${after}" -eq "${before}" ]]
}
assert_ok _neg_name_listed_passes

# 10.5 settings_set 拒绝未知主题名这条断言也是「失败得出来」的：若它反而接受了
# 非法名，assert_fail 会记一次失败，本自检即随之失败。
_neg_settings_rejects() {
  local before="${TESTS_FAIL}" after
  assert_fail settings_set theme "not-a-theme-abc"
  after="${TESTS_FAIL}"
  [[ "${after}" -eq "${before}" ]]
}
assert_ok _neg_settings_rejects

t_summary
