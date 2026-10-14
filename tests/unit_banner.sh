#!/usr/bin/env bash
# tests/unit_banner.sh —— 首页大字符标题块（lib/banner.sh）与设置直达键 `,` 的单元测试。
#
# 被测对象：
#   lib/banner.sh 的冻结接口（BANNER_W/H、BANNER_ACTIVE、BANNER_ROWS、
#   banner_init / banner_render / banner_plain_row / banner_chrome_rows）
#   以及 tui.sh 顶栏的大字符块接线与全局直达键 `,`。
#
# 覆盖：
#   1. 宽度：banner_render 的 6 行每一行显示列恰好 47（用 _core_width 量，绝不用 ${#s}
#      —— █ ═ ║ 是 East Asian Ambiguous，${#s} 量的是字符/字节数，不是显示列）
#   2. 激活门槛的**边界两侧**：UI_COLS 46/47、UI_ROWS 21/22
#   3. 降级条件：BUPTY_AMBIG_W != 1 → 关；非 UTF-8 → 关
#   4. BUPTY_FORCE_BANNER 三态语义（1 强开且**允许**超出 UI_COLS，0 强关，未设置按门槛）
#   5. **降级路径逐字节一致**：块关闭时，与 git HEAD 导出的干净树逐行比 9 帧
#      （8 个视图 × 100×30 + 首页 × 46×22）。判据是「差异行集合恰好是 {页脚提示行}」：
#      除页脚外每一行都必须逐字节相同，而页脚行的差异必须**只由**新增的「c 设置」造成
#      （cur == head + extra，extra 是 " · c 设置" 的前缀）。这是本轮最重要的不变量，
#      用真正的跨树对比做，不是断言一个布尔。
#   6. 不出块 / 出块时都不溢出一行（在 UI_COLS × UI_ROWS 网格上扫）
#   7. 居中：块左右留白差 ≤ 1 列，且左位移恰为 floor((UI_COLS-47)/2)
#   8. chrome：banner_chrome_rows home → 11，任意非 home 视图 → 5
#   9. banner_render 不写 stdout（污染帧缓冲会毁掉整个渲染）
#  10. `,` 直达键：每个视图下都能切到 settings；作业页按 `s` 仍能提交作业（回归护栏）
#  11. 幂等：同尺寸重复调用结果一致；改 UI_COLS 后按新尺寸重判（不缓存）
#
# 负向对照贯穿其中：宽度链路必须能量出「故意超宽」、`,` 驱动必须能因删掉该分支而变红。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 隔离配置目录：避免读到开发者本机已保存的主题。
export XDG_CONFIG_HOME="$(mktemp -d)"
trap 'rm -rf "${XDG_CONFIG_HOME}"' EXIT

# tui.sh 自己 set -euo pipefail；本测试靠断言计数判定成败，载入后立刻关掉 errexit
# （与 tests/unit_home.sh 同一约定：render_home 的合法返回码 1 会静默杀掉整个测试）。
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tui.sh"
set +e
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

ui_size() { :; }
creds_exists() { return 1; }

# 让「是否为 UTF-8 终端」这一条与环境无关：core_utf8 认 BUPTY_FORCE_UTF8=1。
# 不这么做的话，同一份断言在 Git Bash（非 UTF-8）与 WSL（C.UTF-8）下结论相反。
export BUPTY_FORCE_UTF8=1
# 歧义宽度：本文件所有「出块」用例都在 amb=1 下判定（amb=2 单列一节专门测降级）。
BUPTY_AMBIG_W=1

ui_theme_init dark
icon_init
ui_box_init

# ---------------------------------------------------------------------------
# 测试专用小工具
# ---------------------------------------------------------------------------

# 剥 ANSI 转义（只处理 CSI）。刻意不用 ${s//$'\033'\[[0-9;]*[a-zA-Z]/}：bash 的 * 贪婪，
# 会从第一个转义一路删到行尾，量出来恒为 0，测试会「静默地永远通过」。
b_strip() {
  local s="${1:-}" out="" rest
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"
    s="${s#*$'\033['}"
    rest="${s#*[a-zA-Z]}"
    if [[ "${rest}" == "${s}" ]]; then s=""; break; fi
    s="${rest}"
  done
  B_PLAIN="${out}${s}"
}

# 显示列数（结果写 _CORE_W）。**绝不使用 ${#s}**。
b_width() { _core_width "${1:-}"; printf '%s' "${_CORE_W}"; }

# 剥色后的显示列数。
b_plain_width() { b_strip "${1:-}"; b_width "${B_PLAIN}"; }

# 一行开头的空格数（用于居中判定）。
b_leading_spaces() {
  local s="$1" n=0
  while [[ "${s}" == ' '* ]]; do s="${s# }"; n=$((n + 1)); done
  printf '%s' "${n}"
}

# banner_init 的判定结果。调用方负责先摆好 UI_COLS/UI_ROWS/BUPTY_* 全局。
b_gate() { banner_init; printf '%s' "${BANNER_ACTIVE}"; }

# 按当前 TUI_VIEW 把整帧渲染出来，逐行剥色量宽 → 数组 B_FRAME_W。
b_frame_widths() {
  local cols="$1" rows="$2" line
  UI_COLS="${cols}" UI_ROWS="${rows}"
  TUI_FRAME_FILE="$(mktemp)"
  B_FRAME_W=()
  while IFS= read -r line; do
    b_strip "${line}"
    _core_width "${B_PLAIN}"      # 直接用 _core_width，不经会写 stdout 的 b_width
    B_FRAME_W+=("${_CORE_W}")
  done < <(tui_render)
  rm -f "${TUI_FRAME_FILE}"
}

# 帧内宽度超过 limit 的行的行号串（空 = 无溢出）。
b_frame_overflow() {
  local limit="$1" i out=""
  for i in "${!B_FRAME_W[@]}"; do
    (( B_FRAME_W[i] > limit )) && out+="${out:+ }$((i + 1)):${B_FRAME_W[i]}"
  done
  printf '%s' "${out}"
}

# 渲染一帧首页并把**原始**行（保留 ANSI）写进 B_RAW。
b_header_lines() {
  local line
  B_RAW=()
  TUI_VIEW=home
  while IFS= read -r line; do B_RAW+=("${line}"); done < <(tui_render_header)
}

# ---------------------------------------------------------------------------
# 0. 反向对照：先证明量宽链路「失败得出来」
# ---------------------------------------------------------------------------
t_begin "反向对照"
assert_eq "$(b_width 'BUPTY')" "5" "纯 ASCII 量宽必须准确"
# 故意造一条比 47 宽 1 列的行：必须被量出 48（否则「每行 47 列」全是假通过）。
assert_eq "$(b_width "$(printf '%*s' 48 '')")" "48" "48 个空格必须量出 48 列"
assert_eq "$(( $(b_width "$(printf '%*s' 48 '')") != 47 ))" "1" "48 列的行必须被判为「不等于 47」"
# strip 若贪婪吞到行尾，带色行会塌成 0 列。
b_strip "$(core_sgr 244)████$(core_c_reset)"
assert_eq "$(b_width "${B_PLAIN}")" "4" "剥色后 ████ 必须量出 4 列（strip 坏了则恒 0）"

# ---------------------------------------------------------------------------
# 1. 宽度：6 行 × 恰好 47 显示列
# ---------------------------------------------------------------------------
t_begin "块宽度"
banner_render
assert_eq "${#BANNER_ROWS[@]}" "6" "banner_render 必须产出恰好 ${BANNER_H} 行"
for i in 0 1 2 3 4 5; do
  assert_eq "$(b_width "${BANNER_ROWS[$i]}")" "47" "第 ${i} 行显示列必须恰为 BANNER_W=47"
done

# 带颜色时宽度不变（颜色必须零宽）。
banner_render "${UI_ACCENT}"
assert_eq "${#BANNER_ROWS[@]}" "6" "带色渲染仍是 6 行（数组不得累积）"
for i in 0 1 2 3 4 5; do
  assert_eq "$(b_plain_width "${BANNER_ROWS[$i]}")" "47" "带色第 ${i} 行剥色后仍为 47 列"
  assert_eq "$([[ "${BANNER_ROWS[$i]}" == "${UI_ACCENT}"* ]] && printf yes || printf no)" "yes" \
    "带色第 ${i} 行必须以传入的 SGR 开头"
done

# 纯 ASCII 画布行：字节数 = 字符数 = 显示列数，恒 47。
for i in 0 1 2 3 4 5; do
  r="$(banner_plain_row "${i}")"
  assert_eq "${#r}" "47" "banner_plain_row ${i} 长度必须为 47"
  assert_eq "$(b_width "${r}")" "47" "banner_plain_row ${i} 显示列必须为 47"
done
# 越界下标必须钳到边界，而不是返回空串或崩。
assert_eq "$(banner_plain_row -1)" "$(banner_plain_row 0)" "下标 -1 钳到第 0 行"
assert_eq "$(banner_plain_row 99)" "$(banner_plain_row 5)" "下标 99 钳到第 5 行"
assert_eq "$(banner_plain_row 999999)" "$(banner_plain_row 5)" "越界下标必须钳位而非报错"

# BANNER_W / BANNER_H 必须与实测一致（防止「改字体只改数据不改常量」）。
assert_eq "${BANNER_W}" "47" "BANNER_W 必须为 47"
assert_eq "${BANNER_H}" "6" "BANNER_H 必须为 6"
# 每行都恰好 47 列，说明画布数据没有被某个字符（歧义宽度）撑破。
assert_eq "$(b_plain_width "$(banner_plain_row 0)")" "${BANNER_W}" "第 0 行宽度 == BANNER_W"

# ---------------------------------------------------------------------------
# 2. 激活门槛的边界两侧
# ---------------------------------------------------------------------------
t_begin "门槛：UI_COLS 46/47"
unset BUPTY_FORCE_BANNER
BUPTY_AMBIG_W=1
UI_ROWS=30
UI_COLS=45; assert_eq "$(b_gate)" "0" "45 列 < 47 → 不出块"
UI_COLS=46; assert_eq "$(b_gate)" "0" "46 列 < 47 → 不出块（46 是边界外）"
UI_COLS=47; assert_eq "$(b_gate)" "1" "47 列 == BANNER_W → 出块（边界上）"
UI_COLS=48; assert_eq "$(b_gate)" "1" "48 列 → 出块"

t_begin "门槛：UI_ROWS 21/22"
UI_COLS=100
UI_ROWS=20; assert_eq "$(b_gate)" "0" "20 行 < 22 → 不出块"
UI_ROWS=21; assert_eq "$(b_gate)" "0" "21 行 < 22 → 不出块（21 是边界外）"
UI_ROWS=22; assert_eq "$(b_gate)" "1" "22 行 == 门槛 → 出块（边界上）"
UI_ROWS=23; assert_eq "$(b_gate)" "1" "23 行 → 出块"

# 两条门槛是与关系：任一不满足都不出块。
UI_COLS=46 UI_ROWS=22; assert_eq "$(b_gate)" "0" "宽度够否但宽度不足 → 不出块"
UI_COLS=100 UI_ROWS=21; assert_eq "$(b_gate)" "0" "宽度够但高度不足 → 不出块"

# ---------------------------------------------------------------------------
# 3. 降级条件
# ---------------------------------------------------------------------------
t_begin "降级：BUPTY_AMBIG_W != 1"
# amb=2：歧义类实占 2 列，47 列会实占 94 列且居中全错 → 必须整块不显示。
BUPTY_AMBIG_W=2 UI_COLS=200 UI_ROWS=50
assert_eq "$(b_gate)" "0" "BUPTY_AMBIG_W=2 → 不出块（即便 200×50）"
BUPTY_AMBIG_W=0 UI_COLS=200 UI_ROWS=50
assert_eq "$(b_gate)" "0" "BUPTY_AMBIG_W=0（非 1）→ 不出块"
BUPTY_AMBIG_W=1

t_begin "降级：非 UTF-8 终端"
# 子 shell 里把 locale 钉成 C（core_utf8 为假）并撤掉强制 UTF-8 开关。
# 用子 shell 是为了不把 LANG=C 泄漏给后面的用例。
n_utf8="$( (
  unset BUPTY_FORCE_UTF8 BUPTY_FORCE_BANNER
  export LANG=C LC_ALL=C LC_CTYPE=C
  BUPTY_AMBIG_W=1 UI_COLS=200 UI_ROWS=50
  banner_init
  printf '%s' "${BANNER_ACTIVE}"
) )"
assert_eq "${n_utf8}" "0" "非 UTF-8 终端 → 不出块"
# 同一子 shell 里把 UTF-8 开关打开，必须能出块（证明上一条不是「恒 0」）。
y_utf8="$( (
  unset BUPTY_FORCE_BANNER
  export LANG=C LC_ALL=C LC_CTYPE=C BUPTY_FORCE_UTF8=1
  BUPTY_AMBIG_W=1 UI_COLS=200 UI_ROWS=50
  banner_init
  printf '%s' "${BANNER_ACTIVE}"
) )"
assert_eq "${y_utf8}" "1" "强制 UTF-8 后同一尺寸必须出块（否则上一条恒真）"

# ---------------------------------------------------------------------------
# 4. BUPTY_FORCE_BANNER 三态
# ---------------------------------------------------------------------------
t_begin "强制开关三态"
# =1：无视全部门槛强开。**定义上允许超出 UI_COLS**——这条与「绝不溢出」是两回事，
# 后者只对「按门槛判定出来的出块」成立（见第 6 节 banner-on 的扫描上限）。
BUPTY_FORCE_BANNER=1 BUPTY_AMBIG_W=1 UI_COLS=10 UI_ROWS=5
assert_eq "$(b_gate)" "1" "FORCE=1 无视门槛强开"
assert_eq "$(( BANNER_W > UI_COLS ))" "1" "强开时允许块宽 47 超出 UI_COLS=10（这是开关的定义）"
# 强开还要能压过 amb=2（否则「无视门槛」是假的）。
BUPTY_FORCE_BANNER=1 BUPTY_AMBIG_W=2 UI_COLS=10 UI_ROWS=5
assert_eq "$(b_gate)" "1" "FORCE=1 也压过 BUPTY_AMBIG_W=2"

# =0：强关，即便尺寸远超门槛。
BUPTY_FORCE_BANNER=0 BUPTY_AMBIG_W=1 UI_COLS=200 UI_ROWS=50
assert_eq "$(b_gate)" "0" "FORCE=0 在 200×50 下也强关"

# 未设置：按门槛。同一尺寸下分别验「能出」与「不能出」，证明不是恒某值。
unset BUPTY_FORCE_BANNER
BUPTY_AMBIG_W=1 UI_COLS=200 UI_ROWS=50; assert_eq "$(b_gate)" "1" "未设置 + 够大 → 出块"
BUPTY_AMBIG_W=1 UI_COLS=46 UI_ROWS=50;  assert_eq "$(b_gate)" "0" "未设置 + 太窄 → 不出块"

# ---------------------------------------------------------------------------
# 5. 降级路径：做完「两种已知字节变换」后逐字节一致（差异只允许在页脚）
# ---------------------------------------------------------------------------
# 【前提已破，口径重写】原口径是「差异行集合恰好等于 {页脚提示行}：除页脚外逐字节相同」。
# 本分支同时加了两个东西，把那个前提**从字面上**打破了：
#   ① 主题底色 UI_BG —— 帧首多发一次底色、且每个 \033[0m 之后补一次底色；
#   ② 页脚默认提示串尾部新增 ` · c 设置`，且窄终端改成**按 ' · ' 整段丢弃**截断
#      （HEAD 是 core_fit 硬切，会切出半截字）。
# 于是非页脚行也**确实**变了字节。重写的做法是把已知的两处变化**平移掉再严格比**，
# 而不是把断言放宽成「基本一样就行」：
#
#   第 1 层（字节级，除页脚外）：只承认两种**从真实 diff 归纳出来**的变换，做完就要求
#     **逐字节相同**；出现这两种之外的任何差异一律判红并打印双方 %q，视为潜在真实回归。
#       变换 a：head 行里每个裸 \033[0m 之后补一次本主题底色（这正是 UI_RESET 的定义）；
#       变换 b：cur 帧首多出的那一次底色发送（紧贴在 \033[2J 之前）。
#   第 2 层（页脚，新口径，**比旧口径更强**）：期望值由本测试**独立构造**，不调用产品的
#     截断函数；基准是**完整旧提示串** FULL_HEAD（取自 100×30 那帧的 head 页脚，即未被
#     截断的那条），而不是窄终端下 head 那条已经被硬切过的半截串。
#       * 放得下（100×30）：cur == head + " · c 设置"；
#       * 放不下（46×22 / 30×20）：EXPECTED(cols) = 把 (FULL_HEAD + " · c 设置") 按预算
#         cols-2 **按 ' · ' 整段整段地**截断（取放得下的最长段前缀），断言 cur(cols) == EXPECTED(cols)。
#     旧口径下窄终端只要 cur 是「head + 某前缀」就过（head 自己就是半截串）；新口径要求
#     cur 恰好等于独立算出的整段截断结果，半截字、少丢一段、多丢一段都挡不住。
# 做法仍是真的把 HEAD 导出成一棵临时树，两棵树在**同一环境**下渲染同样的帧再比。
# 覆盖 8 个视图 × 100×30（放得下）+ 首页 × 46×22 与 30×20（放不下，两档截断深度），共 10 帧。
# 为了让「真的在跟改动前比」可证伪：HEAD 树里不含 lib/banner.sh，就再断言 HEAD 的
# 全部输出里根本不出现 "c 设置"——回滚本功能时这条立刻失效。
t_begin "降级路径：两种已知变换后逐字节一致（差异只允许在页脚）"

# 从本仓库导出 HEAD 到 <dir>。worktree 的 .git 是文件且可能写着 Windows 盘符路径
# （WSL 里直接读不了），故先试直接 git -C，再试翻译盘符路径后用 --git-dir。
b_export_head() {
  local out="$1" gd wgd
  mkdir -p "${out}"
  if git -C "${BUPTY_HOME}" archive HEAD 2>/dev/null | tar -x -C "${out}" 2>/dev/null \
     && [[ -f "${out}/tui.sh" ]]; then
    return 0
  fi
  gd="$(sed -n 's/^gitdir: //p' "${BUPTY_HOME}/.git" 2>/dev/null)"
  if [[ -n "${gd}" ]]; then
    wgd="$(printf '%s' "${gd}" | sed -E 's#^([A-Za-z]):/#/mnt/\L\1/#')"
    if [[ -d "${wgd}" ]] && git --git-dir="${wgd}" archive HEAD 2>/dev/null | tar -x -C "${out}" 2>/dev/null \
       && [[ -f "${out}/tui.sh" ]]; then
      return 0
    fi
  fi
  return 1
}

B_WORK="$(mktemp -d)"
B_HEAD_TREE="${B_WORK}/head"
B_DUMP="${B_WORK}/dump_frames.sh"
# 一个进程渲染多帧（每帧前打印一行 '===FRAME view cols rows===' 作分隔），
# 免得每帧都付一次 source 全套 lib 的启动开销。用 <<'EOF' 原样写入，不展开变量。
cat > "${B_DUMP}" <<'DUMP_EOF'
#!/usr/bin/env bash
set -uo pipefail
root="$1"; shift
export XDG_CONFIG_HOME="$(mktemp -d)"
export BUPTY_FORCE_BANNER=0
export BUPTY_FORCE_UTF8=1
# shellcheck source=/dev/null
source "$root/tui.sh"
set +e
ui_size() { :; }
creds_exists() { return 1; }
ui_theme_init dark
icon_init
ui_box_init
while (( $# >= 3 )); do
  view="$1"; cols="$2"; rows="$3"; shift 3
  UI_COLS="$cols" UI_ROWS="$rows" TUI_VIEW="$view" HOME_FOCUS=grid HOME_SEL=1
  printf '===FRAME %s %s %s===\n' "$view" "$cols" "$rows"
  TUI_FRAME_FILE="$(mktemp)"
  frame="$(tui_render)"
  rm -f "$TUI_FRAME_FILE"
  # tui_render 末尾补一个「清到屏幕底部」的 \033[J；摘掉它，再吃掉尾随换行，
  # 让最后一行**确定**是页脚提示（不依赖它前面到底有没有那个换行）。
  frame="${frame%$'\033[J'}"
  frame="$(printf '%s' "${frame}")"
  printf '%s\n' "${frame}"
done
DUMP_EOF

# 8 个视图各在 100×30（页脚放得下完整提示）比一次；
# 首页另在 46×22 与 30×20 各比一次（放不下 → 走「按 ' · ' 整段丢弃」的截断，两档深度）。
B_SPECS=(home 100 30 home 46 22 assignments 100 30 schedule 100 30 \
         classrooms 100 30 grades 100 30 exams 100 30 public 100 30 settings 100 30 \
         home 30 20)

# 两棵树都在 dark 主题下渲染（dump 脚本里写死 ui_theme_init dark），
# 所以「本主题底色」就是当前 dark 的 UI_BG；为空则两种变换都退化成恒等，断言会立刻红。
ui_theme_init dark
icon_init
ui_box_init
B_THEME_BG="${UI_BG}"
assert_ok test -n "${B_THEME_BG}"

# 两种已知变换（从真实 diff 归纳，规则写在函数体里，一眼能看出「只承认这两处」）。
# 变换 a：head 行里每个裸 \033[0m → \033[0m + 本主题底色。
b_bg_after_reset() {
  local s="${1:-}" out=""
  while [[ "${s}" == *$'\033[0m'* ]]; do
    out+="${s%%$'\033[0m'*}"$'\033[0m'"${B_THEME_BG}"
    s="${s#*$'\033[0m'}"
  done
  B_NORM="${out}${s}"
}

# 变换 b：cur 帧首多出的一次底色发送（**必须**紧贴 \033[2J）。
# B_STRIPPED=1 表示这一帧确实发过底色；=0 表示没发（那就是「擦屏处露出终端底色」的真实
# 回归，调用方必须判红——注意此时本函数是恒等映射，逐行比较**发现不了**，所以必须单列标志）。
b_strip_lead_bg() {
  local s="${1:-}" rest
  B_STRIPPED=0
  if [[ "${s}" == "${B_THEME_BG}"* ]]; then
    rest="${s#"${B_THEME_BG}"}"
    if [[ "${rest}" == $'\033[2J'* ]]; then B_NORM="${rest}"; B_STRIPPED=1; return 0; fi
  fi
  B_NORM="${s}"
}

# 独立实现的「按 ' · ' 整段整段截断」：按分隔符切段，取能放进 budget 的**最长段前缀**。
# 刻意不复用 tui_render_footer 里「从尾部一段段丢」的循环，也不调用 core_fit——
# 期望值必须由测试自己算，否则「实现改了测试跟着改」会把回归一起吃掉。
b_expect_footer() {
  local full="$1" budget="$2" best="" cand="" seg rest
  rest="${full}"
  while :; do
    if [[ "${rest}" == *" · "* ]]; then
      seg="${rest%% · *}"; rest="${rest#* · }"
    else
      seg="${rest}"; rest=""
    fi
    cand="${cand:+${cand} · }${seg}"
    if (( $(b_plain_width "${cand}") <= budget )); then best="${cand}"; else break; fi
    [[ -n "${rest}" ]] || break
  done
  printf '%s' "${best}"
}

# 把 dump 输出按 '===FRAME ' 标记切成 <dir>/NNN 文件。
b_split_frames() {
  local dir="$2"
  mkdir -p "${dir}"
  rm -rf "${dir:?}"/*
  awk -v dir="${dir}" '
    /^===FRAME / { n++; f = dir "/" sprintf("%03d", n); print > f; next }
    n > 0 { print >> f }
  ' "$1"
}

if b_export_head "${B_HEAD_TREE}"; then
  head_has_banner=0
  [[ -f "${B_HEAD_TREE}/lib/banner.sh" ]] && head_has_banner=1
  bash "${B_DUMP}" "${B_HEAD_TREE}" "${B_SPECS[@]}" > "${B_WORK}/head.txt"
  bash "${B_DUMP}" "${BUPTY_HOME}"   "${B_SPECS[@]}" > "${B_WORK}/cur.txt"
  b_split_frames "${B_WORK}/head.txt" "${B_WORK}/head"
  b_split_frames "${B_WORK}/cur.txt"  "${B_WORK}/cur"

  b_nframes=$(printf '%s\n' "${B_WORK}"/cur/* | wc -l | tr -d '[:space:]')
  assert_eq "${b_nframes}" "10" "应转储 10 帧（8 视图 × 100×30 + 首页 × 46×22 + 首页 × 30×20）"

  # 基准串 FULL_HEAD：第 1 帧（home 100×30，页脚放得下）head 侧的**完整旧提示串**。
  # 先证明它确实是「未截断」的那条：窄终端（第 2 帧）head 自己的页脚必须比它更短。
  mapfile -t b_h1 < "${B_WORK}/head/001"
  b_strip "${b_h1[-1]}"; B_FULL_HEAD="${B_PLAIN}"
  while [[ "${B_FULL_HEAD}" == *' ' ]]; do B_FULL_HEAD="${B_FULL_HEAD%' '}"; done
  mapfile -t b_h2 < "${B_WORK}/head/002"
  b_strip "${b_h2[-1]}"; b_h2f="${B_PLAIN}"
  while [[ "${b_h2f}" == *' ' ]]; do b_h2f="${b_h2f%' '}"; done
  assert_ok test "$(b_plain_width "${b_h2f}")" -lt "$(b_plain_width "${B_FULL_HEAD}")"
  # 新增后的完整提示串 = 完整旧串 + 新增段（顺序与产品一致，见 tui.sh 的默认串）。
  B_NEW_FULL="${B_FULL_HEAD} · c 设置"

  b_nonfooter_bad=0   # 第 1 层：两种已知变换后仍有差异的非页脚行数（必须为 0）
  b_footer_bad=0      # 第 2 层：页脚 != 独立算出的 EXPECTED(cols) 的帧数（必须为 0）
  b_extra_seen=0      # 放得下的宽度（规则①）实际生效的帧数（防规则退化成空集真命题）
  b_narrow_seen=0     # 放不下的宽度（规则②整段截断）实际生效的帧数
  b_a_applied=0       # 变换 a 真的改写了多少行的字节（0 = 变换是恒等，等于没在做归一化）
  b_b_applied=0       # 变换 b 真的摘掉了多少次帧首底色（0 = 同上）
  b_b_missing=0       # 帧首**没**发底色的帧数（必须为 0；这一项不能靠逐行比较发现）
  b_index=0
  for curf in "${B_WORK}"/cur/*; do
    b_index=$((b_index + 1))
    mapfile -t cur_lines  < "${curf}"
    mapfile -t head_lines < "${B_WORK}/head/$(basename "${curf}")"
    n=${#cur_lines[@]}
    assert_eq "${n}" "${#head_lines[@]}" "第 ${b_index} 帧的行数必须与改动前一致"

    # 帧标记行（第 0 行）里带着这帧的列数——第 2 层的预算由它算，不写死。
    b_marker="${cur_lines[0]#===FRAME }"; b_marker="${b_marker%===}"
    read -r b_view b_cols b_rows <<< "${b_marker}"
    assert_ok test -n "${b_cols}"

    # ---- 第 1 层：除页脚外，做完两种已知变换后**逐字节相同** ----
    for ((k = 0; k < n - 1; k++)); do
      b_bg_after_reset "${head_lines[k]}"; hn="${B_NORM}"     # 变换 a 作用于 head 侧
      [[ "${hn}" != "${head_lines[k]}" ]] && b_a_applied=$((b_a_applied + 1))
      cn="${cur_lines[k]}"
      if (( k == 1 )); then                                   # 变换 b 只作用于 cur 帧首内容行
        b_strip_lead_bg "${cn}"; cn="${B_NORM}"
        if (( B_STRIPPED )); then
          b_b_applied=$((b_b_applied + 1))
        else
          # 帧首没发底色 → 变换 b 退化成恒等，逐行比较必然「相等」，必须靠这里判红。
          b_b_missing=$((b_b_missing + 1))
          printf 'FAIL [%s] 第 %s 帧帧首没有发出本主题底色（\\033[2J 会擦出终端原底色）\n' \
            "${TESTS_NAME}" "${b_index}"
        fi
      fi
      [[ "${cn}" == "${hn}" ]] && continue
      b_nonfooter_bad=$((b_nonfooter_bad + 1))
      printf 'FAIL [%s] 第 %s 帧第 %s 行：两种已知变换后仍不同（这不在已归纳的两种形式内，可能是真实回归）\n' \
        "${TESTS_NAME}" "${b_index}" "$((k + 1))"
      printf '  head→变换a: %q\n  cur      : %q\n' "${hn}" "${cn}"
    done

    # ---- 第 2 层：页脚，期望值由测试独立构造 ----
    b_strip "${head_lines[-1]}"; hf="${B_PLAIN}"
    while [[ "${hf}" == *' ' ]]; do hf="${hf%' '}"; done
    b_strip "${cur_lines[-1]}";  cf="${B_PLAIN}"
    while [[ "${cf}" == *' ' ]]; do cf="${cf%' '}"; done
    # 规则②（对所有宽度统一适用）：把「完整新提示串」按预算 cols-2 整段截断。
    b_exp="$(b_expect_footer "${B_NEW_FULL}" "$((b_cols - 2))")"
    if [[ "${cf}" != "${b_exp}" ]]; then
      b_footer_bad=$((b_footer_bad + 1))
      printf 'FAIL [%s] 第 %s 帧（%s 列）页脚 != 独立算出的整段截断结果\n' \
        "${TESTS_NAME}" "${b_index}" "${b_cols}"
      printf '  want: %q\n  got : %q\n' "${b_exp}" "${cf}"
    fi
    # 规则①（放得下的宽度）：cur 必须**恰好**是 head + " · c 设置"。
    # 判据「放得下」= head 自己的页脚就是完整旧串（head 是 core_fit 硬切，短了就说明切过）。
    if [[ "$(b_plain_width "${hf}")" == "$(b_plain_width "${B_FULL_HEAD}")" ]]; then
      b_extra_seen=$((b_extra_seen + 1))
      if [[ "${cf}" != "${hf} · c 设置" ]]; then
        b_footer_bad=$((b_footer_bad + 1))
        printf 'FAIL [%s] 第 %s 帧放得下（%s 列），页脚必须恰为 head + " · c 设置"\n' \
          "${TESTS_NAME}" "${b_index}" "${b_cols}"
        printf '  want: %q\n  got : %q\n' "${hf} · c 设置" "${cf}"
      fi
    else
      b_narrow_seen=$((b_narrow_seen + 1))
    fi
  done

  assert_eq "${b_nonfooter_bad}" "0" \
    "除页脚外 10 帧：做完两种已知变换后必须逐字节相同（超出这两种形式的差异 = 潜在回归）"
  assert_eq "${b_footer_bad}" "0" \
    "10 帧的页脚都必须等于测试独立算出的 EXPECTED（放得下 = head+增量；放不下 = 整段截断）"
  # 两条规则都得真的生效过，否则「全绿」可能只是规则退化成空集真命题。
  assert_ok test "${b_extra_seen}" -ge 1     # 规则①（100×30）确实被验过
  assert_ok test "${b_narrow_seen}" -ge 2    # 规则②（46×22、30×20 两档）确实被验过
  # 两种变换必须真的在改写字节：否则「归一化」是恒等，第 1 层断言会静默地什么都没测。
  assert_ok test "${b_a_applied}" -ge 1
  assert_ok test "${b_b_applied}" -ge 1
  assert_eq "${b_b_missing}" "0" "每一帧帧首都必须发出本主题底色（\033[2J 前必须有底色）"
  if (( head_has_banner == 0 )); then
    assert_eq "$(grep -c 'c 设置' "${B_WORK}/head.txt" || true)" "0" \
      "HEAD 树里根本不应出现「c 设置」（证明确在跟改动前比）"
  fi
else
  # 导不出 HEAD 就说明这条最重要的不变量根本没验证到——如实记失败，不静默跳过。
  assert_eq "无法导出 HEAD" "已导出" "git archive HEAD 失败，跨树对比未能执行（不静默通过）"
fi
rm -rf "${B_WORK}"

# ---------------------------------------------------------------------------
# 6. 零溢出：在 UI_COLS × UI_ROWS 网格上扫
# ---------------------------------------------------------------------------
# 6a. 块关闭（按门槛判定为关）——新增装饰最可能引入的回归就是这里。
t_begin "不出块时零溢出"
unset BUPTY_FORCE_BANNER
BUPTY_AMBIG_W=1
TUI_VIEW=home
b_off_bad=0
for spec in "24 12" "46 22" "47 22" "100 30"; do
  read -r cols rows <<< "${spec}"
  HOME_FOCUS="grid" HOME_SEL=1
  b_frame_widths "${cols}" "${rows}"
  out="$(b_frame_overflow "${cols}")"
  if [[ -n "${out}" ]]; then
    b_off_bad=$((b_off_bad + 1))
    printf 'FAIL [%s] cols=%s rows=%s 溢出：%s\n' "${TESTS_NAME}" "${cols}" "${rows}" "${out}"
  fi
done
assert_eq "${b_off_bad}" "0" "块关闭时任何一行都不得超过 UI_COLS"

# 6b. 块开启（47 <= UI_COLS）：块在 47 列终端上也不许溢出。
t_begin "出块时零溢出"
BUPTY_FORCE_BANNER=1
b_on_bad=0
for spec in "47 22" "60 24" "100 30"; do
  read -r cols rows <<< "${spec}"
  HOME_FOCUS="grid" HOME_SEL=1
  b_frame_widths "${cols}" "${rows}"
  out="$(b_frame_overflow "${cols}")"
  if [[ -n "${out}" ]]; then
    b_on_bad=$((b_on_bad + 1))
    printf 'FAIL [%s] cols=%s rows=%s 溢出：%s\n' "${TESTS_NAME}" "${cols}" "${rows}" "${out}"
  fi
done
assert_eq "${b_on_bad}" "0" "块开启时任何一行都不得超过 UI_COLS（含 47 列边界）"
unset BUPTY_FORCE_BANNER

# 负向对照：往同一条量宽/溢出链路里塞一条必然超宽的行，溢出计数必须涨。
_neg_frame_overflow() {
  local before hit=0 x
  b_frame_widths 47 22
  before="${#B_FRAME_W[@]}"
  B_FRAME_W+=("48")        # 人为加一条 48 列的行（47 列终端下必溢出）
  for x in "${B_FRAME_W[@]}"; do (( x > 47 )) && hit=$((hit + 1)); done
  [[ "${#B_FRAME_W[@]}" -gt "${before}" && "${hit}" -ge 1 ]]
}
t_begin "负向对照：溢出必须能被计数"
assert_ok _neg_frame_overflow

# ---------------------------------------------------------------------------
# 7. 居中
# ---------------------------------------------------------------------------
t_begin "块居中"
BUPTY_FORCE_BANNER=1
BUPTY_AMBIG_W=1
b_center_bad=0
for cols in 47 48 100 101 120; do
  UI_COLS="${cols}" UI_ROWS=30
  b_header_lines
  # 第 1 行是状态行，第 2..7 行是块的 6 行。
  want_left=$(( (cols - BANNER_W) / 2 ))
  for k in 1 2 3 4 5 6; do
    b_strip "${B_RAW[$k]}"
    left="$(b_leading_spaces "${B_PLAIN}")"
    right=$(( cols - left - BANNER_W ))
    if (( left != want_left )) || (( right < 0 )) || (( (left - right) > 1 )) || (( (right - left) > 1 )); then
      b_center_bad=$((b_center_bad + 1))
      printf 'FAIL [%s] cols=%s 第 %s 行：left=%s right=%s（want_left=%s）\n' \
        "${TESTS_NAME}" "${cols}" "$((k + 1))" "${left}" "${right}" "${want_left}"
    fi
  done
done
assert_eq "${b_center_bad}" "0" "块左右留白差必须 ≤ 1 列，且左位移为 floor((UI_COLS-47)/2)"
unset BUPTY_FORCE_BANNER

# ---------------------------------------------------------------------------
# 8. chrome 行数（唯一口径）
# ---------------------------------------------------------------------------
t_begin "chrome 行数"
BUPTY_FORCE_BANNER=1 BUPTY_AMBIG_W=1 UI_COLS=100 UI_ROWS=30
banner_chrome_rows home
assert_eq "${BANNER_CHROME_ROWS}" "11" "首页出块 → chrome 11（1 状态行 + 6 块 + 1 分隔 + 3 页脚）"
# 任意非 home 视图一律 5，即便块本可显示。
for v in assignments schedule classrooms grades exams public settings; do
  banner_chrome_rows "${v}"
  assert_eq "${BANNER_CHROME_ROWS}" "5" "视图 ${v} → chrome 5"
done
# 省略视图名时取当前视图 TUI_VIEW。
TUI_VIEW=assignments; banner_chrome_rows; assert_eq "${BANNER_CHROME_ROWS}" "5" "省略参数时取 TUI_VIEW=assignments → 5"
TUI_VIEW=home; banner_chrome_rows; assert_eq "${BANNER_CHROME_ROWS}" "11" "省略参数时取 TUI_VIEW=home（块开）→ 11"
# 块关时首页也退回 5。
BUPTY_FORCE_BANNER=0; banner_chrome_rows home; assert_eq "${BANNER_CHROME_ROWS}" "5" "首页块关 → chrome 5"
unset BUPTY_FORCE_BANNER
# 未设置且门槛不满足时也退回 5。
UI_COLS=46 UI_ROWS=30; banner_chrome_rows home; assert_eq "${BANNER_CHROME_ROWS}" "5" "46 列 → 首页 chrome 5"
TUI_VIEW=home

# ---------------------------------------------------------------------------
# 9. banner_render 不写 stdout
# ---------------------------------------------------------------------------
t_begin "banner_render 不写 stdout"
out="$(banner_render "${UI_ACCENT}")"
assert_eq "${out}" "" "带色渲染不得向 stdout 输出任何字节"
out="$(banner_render)"
assert_eq "${out}" "" "无参渲染不得向 stdout 输出任何字节"
# 连续两次调用不得让数组长到 12 行。
banner_render
banner_render
assert_eq "${#BANNER_ROWS[@]}" "6" "重复渲染后仍是 6 行（数组先清空再加）"

# ---------------------------------------------------------------------------
# 10. 设置直达键 `c` 与作业提交 `s`
# ---------------------------------------------------------------------------
# 键位史：本分支最初用 `,`，2026-10-14 验收时用户要求改成字母（逗号是标点，中文界面里
# 不好看且易中英混读）；首选 `s` 但已被作业页占用，最终定 `c`（config/配置）。
# 下面每条断言都对着 `c` 重写过，并额外钉住「`,)` 不得复活」。
# 10a. 源码层面：全局 case 里有 `c)` 分支、没有 `s)` 分支（`s` 属于 assignments 的 handler）。
t_begin "全局按键 case"
b_global_arms() { awk '/^tui_main\(\)/{f=1} f && /^}/{exit} f' "${BUPTY_HOME}/tui.sh"; }
arms="$(b_global_arms)"
assert_ok grep -qE '^[[:space:]]*c\)' <<< "${arms}"
assert_ok grep -qE 'tui_switch[[:space:]]+settings' <<< "${arms}"
# 旧键必须退役：逗号留在全局 case 里，用户按 `,` 仍会跳设置，等于改了个寂寞。
assert_eq "$(grep -cE '^[[:space:]]*,\)[[:space:]]*' <<< "${arms}")" "0" \
  "全局 case 不得再有 ,) 分支（旧键要真退役，不能只是换了新键）"
assert_eq "$(grep -cE '^[[:space:]]*s\)[[:space:]]*' <<< "${arms}")" "0" \
  "全局 case 不得有 s) 分支（那会抢走作业页的提交键）"
assert_eq "$(grep -cE '^[[:space:]]*q\|EOF\)' <<< "${arms}")" "1" \
  "全局 case 应仍是 tui_main 那段（防 awk 抓空导致上面的断言假通过）"

# 10b. 行为层面：用一个假的按键队列真的驱动 tui_main，看视图有没有切过去。
# ui_read_key 被替换成「按序吐 token」；tui_render 被替换成「把当前视图写进日志」。
# 整个驱动跑在子 shell 里，不污染本测试的全局状态。
b_drive_main() {
  local log="$1" start="$2"; shift 2
  (
    set +e
    TUI_QUIT=0; TUI_STATUS=""; TUI_NAV_STACK=(); TUI_VIEW="${start}"
    B_KEYS=("$@")
    B_LOG="${log}"; B_IDX="$(mktemp)"; printf '0' > "${B_IDX}"
    ui_theme_init() { :; }
    ui_size() { :; }
    creds_load() { return 0; }
    ui_raw_mode() { :; }
    ui_hide_cursor() { :; }
    ui_enter_alt_screen() { :; }
    ui_exit_alt_screen() { :; }
    ui_restore_mode() { :; }
    icon_init() { :; }
    ui_box_init() { :; }
    _async_stop() { :; }
    tui_render() { printf '%s\n' "${TUI_VIEW}" >> "${B_LOG}"; }
    ui_read_key() {
      local n
      n=$(( $(cat "${B_IDX}") + 1 )); printf '%s' "${n}" > "${B_IDX}"
      if (( n > ${#B_KEYS[@]} )); then printf 'q'; return 0; fi
      printf '%s' "${B_KEYS[$((n - 1))]}"
    }
    tui_main
    rm -f "${B_IDX}"
  )
}

t_begin "c 直达键：每个视图都能切到 settings"
for v in "${TUI_TABS[@]}"; do
  L="$(mktemp)"
  b_drive_main "${L}" "${v}" "c" "q"
  mapfile -t got < "${L}"
  assert_eq "${got[0]:-}" "${v}" "从 ${v} 起步时首帧视图应为 ${v}"
  assert_eq "${got[1]:-}" "settings" "在 ${v} 下按 c 应切到 settings"
  rm -f "${L}"
done

# 负向对照：按一个没人处理的普通字符，视图必须**不动**——证明上面的驱动不是「恒切页」。
t_begin "c 驱动的负向对照"
L="$(mktemp)"
b_drive_main "${L}" "home" "z" "q"
mapfile -t got < "${L}"
assert_eq "${got[1]:-}" "home" "按未绑定的 z 不得切页（否则上面的断言是恒真的）"
rm -f "${L}"

# 负向对照二：旧键 `,` 也必须不再切页。上面 10a 钉的是源码，这里钉的是行为——
# 万一哪天有人在别处（如某个 handle_*_key）又给 `,` 加了切页逻辑，这条会红。
t_begin "旧键 , 已退役（行为层）"
L="$(mktemp)"
b_drive_main "${L}" "home" "," "q"
mapfile -t got < "${L}"
assert_eq "${got[1]:-}" "home" "按已退役的 , 不得再跳设置"
rm -f "${L}"

# 10c. 回归护栏：全局 `c` 不得削掉作业页既有的 `s` 提交功能。
t_begin "作业页 s 仍能提交"
# 直接替换提交流程为可观测的桩：handler 认不认 `s` 立刻可见。
# （不能用「子 shell 里置全局标志」——$( ) 的赋值传不回来。）
_assignments_submit_flow() { printf 'SUBMIT'; }
assignments_refresh() { printf 'RELOAD'; }
out="$(handle_assignments_key s)"
assert_eq "${out}" "SUBMIT" "作业页按 s 必须仍调用提交流程"
out="$(handle_assignments_key ENTER)"
assert_eq "${out}" "SUBMIT" "作业页按 ENTER 也必须提交"
out="$(handle_assignments_key r)"
assert_eq "${out}" "RELOAD" "作业页按 r 应走刷新而非提交（证明上面的 SUBMIT 不是恒输出）"
# 全局 case 里不得存在 s) —— 这正是「作业页 s 被抢走」的成因。
assert_eq "$(grep -cE '^[[:space:]]*s\)[[:space:]]*' <<< "$(b_global_arms)")" "0" \
  "全局 case 出现 s) 会让作业页提交永久失效"

# ---------------------------------------------------------------------------
# 11. 幂等 / 不缓存
# ---------------------------------------------------------------------------
t_begin "幂等与不缓存"
BUPTY_AMBIG_W=1 UI_COLS=100 UI_ROWS=30
banner_init; a1="${BANNER_ACTIVE}"
banner_init; a2="${BANNER_ACTIVE}"
banner_init; a3="${BANNER_ACTIVE}"
assert_eq "${a1}/${a2}/${a3}" "1/1/1" "同一尺寸反复 banner_init 结果一致"
assert_eq "$(banner_init; banner_init; printf '%s' "${BANNER_ACTIVE}")" "1" "连续两次调用仍为 1"

# 改尺寸后必须按新尺寸重判（不能把首次结果锁死）。
UI_COLS=40
assert_eq "$(b_gate)" "0" "UI_COLS 改成 40 后必须重判为关"
UI_COLS=100
assert_eq "$(b_gate)" "1" "UI_COLS 改回 100 后必须重判为开"
UI_ROWS=10
assert_eq "$(b_gate)" "0" "UI_ROWS 改成 10 后必须重判为关"
UI_ROWS=30
assert_eq "$(b_gate)" "1" "UI_ROWS 改回 30 后必须重判为开"

t_summary
