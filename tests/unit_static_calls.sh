#!/usr/bin/env bash
# tests/unit_static_calls.sh —— 静态扫描：「命令位置上的项目标识符」必须真的有定义。
#
# 动机：本轮三处缺陷是同一个形状——**调用点少了一个字符**：
#     lib/views/settings.sh   creds_clea          （应为 creds_clear，登出根本没删文件）
#     lib/views/settings.sh   _render_settings_picke（应为 _render_settings_picker）
#     tui.sh                  tui_rende           （应为 tui_render）
# 这类缺陷 bash 在**运行到那一行之前**不会报错，单元测试又只覆盖走过的分支，所以
# 要靠静态扫描兜住「名字打错/函数不存在」。
#
# 判据（三段合取，缺一不可）：
#   ① 出现在**命令位置**：行首（可带缩进），或紧跟 `;` `&` `|` `(` `{` `!` `$` 之后；
#   ② 以**项目前缀**开头：前缀由「本仓库真实定义过的函数名」自动归纳（到 '_' 截断、长度 ≥3），
#      不是手写白名单——新加一个 `foo_bar()` 就自动多出 `foo_` 前缀；
#   ③ 该标识符在整个扫描范围内**从未被定义为函数**。
#
# 【必须避开的四类误报】（前两类是文档里点名的，后两类是本文件实测补上的）：
#   ① jq 程序串：`autostart_enabled:` / `notify_interval)` —— 扫描器先剥掉单引号字符串，
#      jq 程序在本仓库一律用单引号包裹，于是整段消失；残留的 case 分支模式（`a|b)`）
#      由「标识符后面必须是空白或行尾」这一条挡掉。
#   ② `x=0` 形式赋值：`settings_wide=0` —— 标识符后面紧跟 `=`，不算命令位置。
#   ③ 测试局部变量/助记符：`theme_dark_sig="$(...)"`、`weeks+=` —— 同上，后面是 `=` / `+=`。
#   ④ `${...}` 参数展开里的变量：`${_ICON_RESET}`、`${_CORE_W}` —— 前面是 `${`，不算命令位置。
#   （③④ 与「后界必须是空白」合起来还顺带挡掉了 `case` 分支模式 `autostart_enabled|...`）
#
# 【引号上下文】（两次事故的护栏）
#   引号状态**每行清零**，且双引号里的 `'` 不开启单引号串。两次事故都出在这上面：
#   * 第一版跨文件泄漏：前一个文件落单的 `'` 让**后面所有文件**整段被吞，三处真缺陷全漏报；
#   * 第二版跨行泄漏：`"$(printf '%d' "'${key}")"`（lib/ui.sh:635）这种嵌套写法让
#     `'` 在本行开了一个永不闭合的单引号串，吞掉 lib/ui.sh 第 635 行往后的 48 行核心渲染。
#   两条都由下方哨兵钉死。
#
# 【诚实声明的盲区】
#   * 标识符后面紧跟 `)` 的零参调用（`$(core_today)`）不扫描——正是这条换来了 case 模式不误报；
#   * 若某个拼错的名字恰好等于另一个**已存在**的函数名，扫不出来（文档已承认同类盲区）；
#   * 只做词法，不做作用域分析：扫描范围内的函数定义全局可见；
#   * 未闭合的引号仍会让**本文件**该引号往后的内容漏扫（这是 bash 里本就非法的写法，
#     产品代码无此情形；回归护栏见下方「单引号状态不得跨文件泄漏」哨兵）。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LANG=C.UTF-8
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

S_WORK="$(mktemp -d)"
trap 'rm -rf "${S_WORK}"; [[ -n "${S_SYNTH:-}" ]] && rm -rf "${S_SYNTH}"' EXIT

# 扫描范围：产品代码 + 测试（测试里也有会拼错的项目调用）。
S_FILES=()
while IFS= read -r f; do S_FILES+=("${f}"); done < <(
  cd "${BUPTY_HOME}" && ls lib/*.sh lib/**/*.sh tui.sh tests/unit_*.sh tests/lib/*.sh 2>/dev/null |
    sort -u | sed "s#^#${BUPTY_HOME}/#" |
    # 排除本文件自己：它内部含**故意拼错**的合成样本（creds_clea 等），
    # 扫到自己会变成「哨兵污染」，与「真实代码有没有拼错」这件事无关。
    grep -v '/unit_static_calls\.sh$'
)
[[ -d "${BUPTY_HOME}/bin" ]] && while IFS= read -r f; do S_FILES+=("${f}"); done < <(
  cd "${BUPTY_HOME}" && ls bin/* 2>/dev/null | sed "s#^#${BUPTY_HOME}/#"
)

# ---------------------------------------------------------------------------
# 扫描器：另存成文件，避免把 awk 程序塞进命令行引号里（PowerShell/WSL 都会吃引号）。
# ---------------------------------------------------------------------------
S_SCAN="${S_WORK}/scan.sh"
cat > "${S_SCAN}" <<'SCAN_EOF'
#!/usr/bin/env bash
# 用法：scan.sh <文件...>   —— 输出 <file>:<line>: <未定义标识符>
# 定义集与前缀表由**同一批文件**归纳，保证「扫描到的东西和它依赖的定义来自同一个世界」。
set -uo pipefail
files=("$@")

# ① 定义集：所有 `name() {` / `function name {` 形式的函数名。
defs="$(grep -hoE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "${files[@]}" 2>/dev/null |
  sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\).*$//' | sort -u)"

# ② 前缀表：从定义集自动归纳——每个 '_' 处截断，长度 ≥3 才算（挡掉 `_`、`t_`、`b_` 这类
#    过短前缀；也挡掉 `${_CORE_W}` 这种「短前缀 + 全大写变量」）。
prefixes="$(printf '%s\n' "${defs}" | awk '
  { n = length($0); for (i = 2; i <= n; i++) if (substr($0, i, 1) == "_") print substr($0, 1, i) }
' | sort -u | awk 'length($0) >= 3' | tr '\n' ' ')"

awk -v defs="${defs}" -v prefixes="${prefixes}" '
BEGIN {
  nd = split(defs, da, "\n"); for (i = 1; i <= nd; i++) if (da[i] != "") def[da[i]] = 1
  np = split(prefixes, pa, " "); for (i = 1; i <= np; i++) if (pa[i] != "") pre[pa[i]] = 1
  in_sq = 0; in_dq = 0
}
{
  # --- 剥掉单引号串、双引号串的引号、注释、算术展开 ---
  #
  # 引号状态**每行清零**（不跨行、更不跨文件）。这一条是打补丁打出来的：
  # bash 里「双引号内再套一个单引号字符串」的嵌套写法（lib/ui.sh:635 取字符码那行
  # 就是），任何「跨行维护单引号状态」的朴素模型都会在里层右括号之后的那个单引号上
  # 误判，进而在**本行**开启一个永不闭合的单引号串——若不按行清零，它会一直吞到
  # 文件尾（实测吞掉 lib/ui.sh 第 635 行往后 48 行核心渲染）。
  # 代价：真正跨行的单引号串会漏扫。本仓库实测**不存在**这种写法（详见文件头盲区说明），
  # 且 Section B 会对真实代码断言 0 条，一旦将来引入就会立刻暴露。
  # 注意：本 awk 程序整个被 shell 单引号包着，注释里**绝不能出现裸的单引号字符**，
  # 否则 shell 字符串会在那里提前闭合（本文件的第一版补丁就是这么把自己弄哑的）。
  in_sq = 0; in_dq = 0
  line = $0; out = ""; n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (in_sq) { if (c == "\x27") in_sq = 0; i++; continue }
    # 双引号串**不整段跳过**：`"$(tui_render)"` 这类子命令里的调用点仍要能扫到。
    # 只把引号本身吃掉；双引号内的单引号是普通字符、井号也不是注释起头。
    if (in_dq) {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") { in_dq = 0; i++; continue }
      out = out c; i++; continue
    }
    if (c == "\\") { i += 2; continue }
    if (c == "\"") { in_dq = 1; i++; continue }
    if (c == "\x27") { in_sq = 1; i++; continue }
    if (c == "#") {
      p = (i == 1) ? "" : substr(line, i - 1, 1)
      if (p == "" || p ~ /[ \t;&|()]/) break
    }
    # `$(( ... ))` / `(( ... ))` 是算术展开：里面的标识符是变量名，不是命令。
    # （实测误报：`settings_wide=$((settings_wide + 1))` 里的内层被当成了命令位置。）
    if (c == "(" && substr(line, i + 1, 1) == "(") {
      depth = 0; i += 2
      while (i <= n) {
        c2 = substr(line, i, 1)
        if (c2 == "(") depth++
        else if (c2 == ")") {
          if (depth == 0 && substr(line, i + 1, 1) == ")") { i += 2; break }
          if (depth > 0) depth--
        }
        i++
      }
      out = out " "   # 占位，保持词边界
      continue
    }
    out = out c
    i++
  }
  if (out == "") next

  # 注意：这里必须用「原地推进 pos」而不是 `s = substr(s, en+1)`。
  # 后者会把左侧上下文一起丢掉，于是 `foo bar_baz` 里的实参 `bar_baz` 会变成
  # 「行首」——第一版就是这么把 7 处实参误报成命令的。
  s = out
  pos = 1
  while (pos <= length(s)) {
    rest = substr(s, pos)
    if (!match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) break
    st = pos + RSTART - 1
    en = st + RLENGTH - 1
    tok = substr(s, st, RLENGTH)
    aft = (en < length(s)) ? substr(s, en + 1, 1) : ""
    # 后界：必须是空白或行尾 —— 这一条同时挡掉 `x=0`、`w+=`、`jq_key:`、`case 模式)`、
    #       以及 `a|b` 里的 a。（代价：`$(zero_arg_call)` 这种零参调用不扫描，已声明。）
    ok_after = (aft == "" || aft == " " || aft == "\t") ? 1 : 0
    # 前界：行首，或紧跟命令分隔符/子命令括号之后。
    j = st - 1
    while (j >= 1 && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) j--
    if (j < 1) {
      ok_before = 1
    } else {
      pc = substr(s, j, 1)
      # `${...}` 里的变量不是命令位置。
      if (pc == "{" && j >= 2 && substr(s, j - 1, 1) == "$") ok_before = 0
      else ok_before = (pc ~ /[;&|({!$]/) ? 1 : 0
    }
    if (ok_after && ok_before && tok !~ /^[A-Z]/ && !(tok in def)) {
      haspre = 0
      for (p in pre) if (index(tok, p) == 1) { haspre = 1; break }
      if (haspre) print FILENAME ":" FNR ": " tok
    }
    pos = en + 1
  }
}
' "${files[@]}"
SCAN_EOF

# ---------------------------------------------------------------------------
# A. 反向对照：合成输入上，扫描器必须「该报的报、该放的放」
# ---------------------------------------------------------------------------
# 一台固定的扫描器在合成目录上跑：既有真调用（用真名字），也有三/四类误报诱饵。
t_begin "静态扫描：合成输入上的灵敏度与误报"
S_SYNTH="$(mktemp -d)"
mkdir -p "${S_SYNTH}"
cat > "${S_SYNTH}/defs.sh" <<'EOF'
ui_paint() { printf '%s' "$1"; }
creds_clear() { rm -f x; }
autostart_is_enabled() { return 0; }
settings_set() { return 0; }
EOF
cat > "${S_SYNTH}/uses.sh" <<'EOF'
ui_paint ok
creds_clea
if creds_clear; then ui_paint yes; fi
x=0; settings_wide=0; weeks+=(1)
theme_dark_sig="$(ui_paint 'sig')"
jq -n '{autostart_enabled:false, notify_interval:60}'
case "$k" in
  autostart_enabled|notify_interval) ui_paint k ;;
esac
printf '%s\n' "${_CORE_W}"
EOF
S_OUT="$(bash "${S_SCAN}" "${S_SYNTH}/defs.sh" "${S_SYNTH}/uses.sh" 2>/dev/null)"
# 必须抓到：`creds_clea`（真·少一个字符）。
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c 'creds_clea' || true)" "1" \
  "命令位置上的 creds_clea 必须被抓到"
# 必须放过：三/四类误报一个都不能出现。
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c 'autostart_enabled' || true)" "0" \
  "jq 程序串/case 模式里的 autostart_enabled 不得误报"
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c 'notify_interval' || true)" "0" \
  "jq 程序串/case 模式里的 notify_interval 不得误报"
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c 'settings_wide' || true)" "0" \
  "赋值形式 settings_wide=0 不得误报"
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c 'theme_dark_sig' || true)" "0" \
  "测试局部变量 theme_dark_sig=... 不得误报"
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c 'weeks' || true)" "0" \
  "累加形式 weeks+= 不得误报"
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c '_CORE_W' || true)" "0" \
  "参数展开里的变量（dollar-brace _CORE_W）不得误报"
# 而且整台扫描器在合成输入上**只**报出那一条（防止「顺手多报一堆」也算过）。
assert_eq "$(printf '%s\n' "${S_OUT}" | grep -c . || true)" "1" \
  "合成输入上应恰好只报出 1 条"

# 反向对照②：单引号状态**不得跨文件泄漏**。
# 第一版扫描器正是死在这里：某个文件里落单的 `'` 让其后**所有**文件被整段当成字符串
# 吞掉，于是三处真缺陷全部漏报、测试却是绿的。这条哨兵就是那次事故的回归护栏。
cat > "${S_SYNTH}/leak.sh" <<'EOF'
ui_paint '一个没闭合的单引号
EOF
cat > "${S_SYNTH}/after.sh" <<'EOF'
creds_clea
EOF
S_OUT2="$(bash "${S_SCAN}" "${S_SYNTH}/defs.sh" "${S_SYNTH}/leak.sh" "${S_SYNTH}/after.sh" 2>/dev/null)"
assert_eq "$(printf '%s\n' "${S_OUT2}" | grep -c 'after.sh:1: creds_clea' || true)" "1" \
  "前一个文件残留单引号状态时，后面文件里的缺陷仍必须被抓到（跨文件状态不得泄漏）"

# 反向对照③：**同一个文件内**，嵌套引号写法不得吞掉后面的行。
# 第二版扫描器死在这里：`"$(printf '%d' "'${k}")"`（lib/ui.sh:635 的真实形状）里
# 里层 `)` 之后那个 `'` 被误当成单引号串开头，且跨行一直不闭合，把**本文件**
# 第 635 行往后的 48 行核心渲染整段吞掉——测试却是绿的。
cat > "${S_SYNTH}/nested.sh" <<'EOF'
printf '%s' "$(printf '%d' "'${k}")"
creds_clea
EOF
S_OUT3="$(bash "${S_SCAN}" "${S_SYNTH}/defs.sh" "${S_SYNTH}/nested.sh" 2>/dev/null)"
assert_eq "$(printf '%s\n' "${S_OUT3}" | grep -c 'nested.sh:2: creds_clea' || true)" "1" \
  "嵌套引号行之后的同文件缺陷仍必须被抓到（引号状态不得跨行残留）"
assert_eq "$(printf '%s\n' "${S_OUT3}" | grep -c . || true)" "1" \
  "那行嵌套引号本身不得产生任何误报"

# ---------------------------------------------------------------------------
# B. 真实代码：0 条未定义调用
# ---------------------------------------------------------------------------
t_begin "静态扫描：真实代码里没有未定义的命令位置标识符"
assert_ok test "${#S_FILES[@]}" -ge 15
S_REAL="$(bash "${S_SCAN}" "${S_FILES[@]}" 2>/dev/null)"
if [[ -n "${S_REAL}" ]]; then
  printf '%s\n' "${S_REAL}" | head -30
fi
assert_eq "$(printf '%s' "${S_REAL}" | grep -c . || true)" "0" \
  "扫描范围内不得存在「命令位置 + 项目前缀 + 从未定义」的标识符"

t_summary
