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
#   2. 激活门槛的**边界两侧**：UI_COLS 46/47、UI_ROWS 按宽度分档（>=79 列要 29 行、
#      47..78 列要 28 行，都是「块 chrome 11 + 页签条 2 + 该档位 body」），并断言门槛
#      对行数单调（不许忽 0 忽 1）
#   3. 降级条件：BUPTY_AMBIG_W != 1 → 关；非 UTF-8 → 关
#   4. BUPTY_FORCE_BANNER 三态语义（1 强开且**允许**超出 UI_COLS，0 强关，未设置按门槛）
#   5. **开/关底色只差两处已知变换**（同一棵树自比）：同一批 11 帧规格渲染两份，
#      一份开整屏底色、一份关掉，断言两份输出**逐行逐字节只差两类字节**（详见第 5 节头注）。
#      这是本轮最重要的不变量：整屏底色只允许影响「每个 reset 后补一次底色」与
#      「帧首擦屏前发一次底色」这两处，别的字节一个都不许动。
#   6. 不出块 / 出块时都不溢出一行（在 UI_COLS × UI_ROWS 网格上扫）
#   7. 居中：块左右留白差 ≤ 1 列，且左位移恰为 floor((UI_COLS-47)/2)
#   8. chrome：banner_chrome_rows 的冻结口径——base 5（非 home）/ 11（home 出块），
#      页签条放得下时 +2（→ 13/7），并钉住宽度与高度两条子句的边界两侧
#   9. banner_render 不写 stdout（污染帧缓冲会毁掉整个渲染）
#  10. `c` 直达键：每个视图下都能切到 settings；作业页按 `s` 仍能提交作业（回归护栏）
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

# 渲染「状态行 + 大块」并把**原始**行（保留 ANSI）写进 B_RAW：B_RAW[0] 是状态行、
# B_RAW[1..6] 是块的 6 行。刻意不含页签条（页签条由 tui_render 画，居中判定用不着它，
# 含进来只会把块的固定下标搅乱）。
b_header_lines() {
  local line
  B_RAW=()
  TUI_VIEW=home
  while IFS= read -r line; do B_RAW+=("${line}"); done < <(tui_render_statusline)
  while IFS= read -r line; do B_RAW+=("${line}"); done < <(tui_render_bannerblock)
}

# 渲染整帧首页（tui_render），保留 ANSI 的原始行写进 B_RAW —— 用来钉死**版式顺序**：
# 状态行 / 页签条 / 大块 各自必须落在哪一行。与 b_frame_widths 同源但保留颜色。
b_full_frame() {
  local line
  B_RAW=()
  TUI_VIEW=home
  TUI_FRAME_FILE="$(mktemp)"
  while IFS= read -r line; do B_RAW+=("${line}"); done < <(tui_render)
  rm -f "${TUI_FRAME_FILE}"
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

t_begin "门槛：UI_ROWS 按宽度分档"
# 高度门槛不是一个平铺常数：块显示后 chrome base=11，页签条再占 2 行，二者加上
# 「该宽度档位所需的 body」才是门槛（档位表与算式在 lib/banner.sh 的函数头注释里）：
#   79..97 列 → 首页档位 A2，body 下限 16 → 11 + 2 + 16 = 29
#   40..78 列 → 首页档位 B， body 下限 15 → 11 + 2 + 15 = 28
# 这里的期望不由产品函数算出来，而是**扫**出来：b_flip 扫 8..40 行，取最小的、出块的
# 那一行；扫不到打 none。翻转点必须与上面那条独立算式一致才算过。同时断言整段扫描
# 单调（一旦翻到 1 就不许再回 0）——否则 WINCH 后块会忽隐忽现。
b_flip() {  # <UI_COLS> → 最小出块行数，扫不到打 none
  local c="$1" r
  UI_COLS="${c}"
  for ((r = 8; r <= 40; r++)); do
    UI_ROWS="${r}"
    [[ "$(b_gate)" == "1" ]] && { printf '%s' "${r}"; return; }
  done
  printf 'none'
}
b_gate_monotone() {  # <UI_COLS> → 出现「1 之后又回 0」的次数（必须为 0）
  local c="$1" r prev=-1 g bad=0
  UI_COLS="${c}"
  for ((r = 8; r <= 40; r++)); do
    UI_ROWS="${r}"; g="$(b_gate)"
    (( g < prev )) && bad=$((bad + 1))
    prev="${g}"
  done
  printf '%s' "${bad}"
}
assert_eq "$(b_flip 100)" "29" "100 列（档位 A2，body 16）→ 29 = 11+2+16 才出块"
assert_eq "$(b_flip 79)"  "29" "79 列（档位 A2 的下沿）→ 同 29"
assert_eq "$(b_flip 78)"  "28" "78 列（档位 B，body 15）→ 28 = 11+2+15 才出块"
assert_eq "$(b_flip 47)"  "28" "47 列（刚好放得下块）→ 高度门槛仍 28"
assert_eq "$(b_flip 46)"  "none" "46 列 → 宽度子句否决，再高也不出块"
assert_eq "$(b_gate_monotone 100)" "0" "100 列：门槛随行数单调（1 之后不许回 0）"
assert_eq "$(b_gate_monotone 78)"  "0" "78 列：同上（分档边界不许抖动）"

# 翻转点两侧：翻转行出块，上一行不出块，再上一行也出块。
UI_COLS=100
UI_ROWS=28; assert_eq "$(b_gate)" "0" "100 列 28 行 < 29 → 不出块（边界外）"
UI_ROWS=29; assert_eq "$(b_gate)" "1" "100 列 29 行 == 门槛 → 出块（边界上）"
UI_ROWS=30; assert_eq "$(b_gate)" "1" "100 列 30 行 → 出块"
UI_COLS=78
UI_ROWS=27; assert_eq "$(b_gate)" "0" "78 列 27 行 < 28 → 不出块（边界外）"
UI_ROWS=28; assert_eq "$(b_gate)" "1" "78 列 28 行 == 门槛 → 出块（边界上）"

# 分档门槛要保证的不变量：块一旦显示，页签条的高子句在任何视图下都同时成立，
# 于是同一尺寸下 9 个视图的 BANNER_TABBAR_ROWS 必须取同一个值——否则切页时页签条
# 忽隐忽现。（关键是「所有视图相同」，不是「一定等于 2」：47..55 列那档页签条本来就
# 被宽度子句挡掉，取值应是 0，但 9 个视图仍必须齐。）
# 扫描式检查（不是只测一个尺寸）：凡 b_gate 说「出块」的 (列,行) 组合，9 个视图的
# BANNER_TABBAR_ROWS 都必须取同一个值。用扫描而不是钉单点，是为了让这条断言真的
# 能证伪「把高度门槛降到 22」这类改动——那时 22..24 行会出块，而 home 的高子句
# (rows-11-2 >= 12) 不成立、其余视图 (rows-5-2) 成立，页签条就在切页时闪烁。
b_flick_bad=0; b_flick_checked=0; b_flick_on=0
for b_cols in 100 78 47; do
  for ((b_r = 20; b_r <= 40; b_r++)); do
    UI_COLS="${b_cols}" UI_ROWS="${b_r}"
    [[ "$(b_gate)" == "1" ]] || continue
    b_flick_on=$((b_flick_on + 1))
    b_vals=""
    for b_v in "${TUI_TABS[@]}"; do
      banner_chrome_rows "${b_v}"
      b_vals+="${BANNER_TABBAR_ROWS} "
    done
    b_first="${b_vals%% *}"
    b_flick_checked=$((b_flick_checked + 1))
    for b_x in ${b_vals}; do
      [[ "${b_x}" == "${b_first}" ]] || { b_flick_bad=$((b_flick_bad + 1)); break; }
    done
  done
done
assert_eq "${b_flick_checked}" "${b_flick_on}" "每个「出块」尺寸都要真的被检查过（非空集）"
assert_eq "$(( b_flick_checked >= 20 ))" "1" "出块的尺寸样本必须够多（实测 20..40 行 × 3 档列）"
(( b_flick_bad == 0 )) || printf 'FAIL [%s] 页签条在 %s 个尺寸上出现跨视图不一致\n' \
  "${TESTS_NAME}" "${b_flick_bad}"
assert_eq "${b_flick_bad}" "0" "出块时 9 个视图的 BANNER_TABBAR_ROWS 必须处处一致（页签条不许闪）"
# 非空集 / 取值锚点：100×29 应放得下页签条（2），47 列那档页签条被宽度子句挡掉（0）。
UI_COLS=100 UI_ROWS=29; banner_chrome_rows home
assert_eq "${BANNER_TABBAR_ROWS}" "2" "100×29 下页签条放得下 → 2 行"
UI_COLS=47 UI_ROWS=29; banner_chrome_rows home
assert_eq "${BANNER_TABBAR_ROWS}" "0" "47 列：宽度子句否决页签条 → 0 行"

# 两条门槛是与关系：任一不满足都不出块。
UI_COLS=46 UI_ROWS=40; assert_eq "$(b_gate)" "0" "宽度不足 → 不出块（高度再高也没用）"
UI_COLS=100 UI_ROWS=28; assert_eq "$(b_gate)" "0" "宽度够但高度不足 → 不出块"

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
# 【口径重写】原口径把工作区跟 `git archive HEAD` 导出的干净树逐字节比。合并后 HEAD
# 本身就含这个功能、工作区还并进了 main 的并行改动，那个基准自我指涉、彻底失效。
# 新口径是**同一棵树自比**：同一批帧规格渲染两份，一份开整屏底色（UI_BG = 本主题底色，
# 即 ui_theme_init 后的正常状态），一份把底色**关掉**（UI_BG 置空、UI_RESET 退回纯
# \033[0m），断言两份输出**逐行逐字节只差下面两类字节**：
#
#   变换 a（逐行，全帧）：关底色帧里每一个裸 \033[0m 之后插入一次本主题底色。
#     这正是 UI_RESET 的定义（core_c_reset + UI_BG），也是对「底色只经由 UI_RESET 出现」
#     的断言：某处 \033[0m 之后没跟底色 → 按变换 a 补上后仍与开底色帧对不上 → 判红
#     （真回归：那里底色会断开）。
#   变换 b（帧首，**恒等映射**）：开底色帧第 1 行必须以「底色 + \033[2J」开头。
#     关底色帧第 1 行没有这段底色（它开头直接就是 \033[2J），所以变换 b 不改变任何字节
#     ——逐行比较**发现不了**它，必须单列 B_STRIPPED 标志去钉「帧首确实发过底色」。
#     （tui_render 起手 `printf '%s' "${UI_BG}"` 再 \033[2J，依赖 BCE 让擦屏自带底色。）
#
# 可证伪性（防退化，计数器见下）：
#   * 空集验证：每帧都必须 bg != no_bg，否则不变量恒真、什么都没验 → b_same_frames 必须为 0；
#   * 变换 a 必须真的改写字节（b_a_applied ≥ 1），否则「归一化」是恒等映射、白比；
#   * 变换 b 必须真的命中且一帧不漏（b_b_applied ≥ 1 且 b_b_missing == 0）；
#   * 每行显示宽度 ≤ UI_COLS（b_overflow_bad == 0）。
#
# 页脚（第 2 类断言，期望值由本测试**独立构造**，不调用产品的截断函数）：
#   * 产品默认提示串写死在测试里（B_DEFAULT_HINT），并断言 tui.sh 里那一条**逐字等于**它；
#   * 放得下（宽度 ≤ 预算 cols-2）：渲染出的页脚 == B_DEFAULT_HINT；
#   * 放不下：== b_expect_footer(B_DEFAULT_HINT, cols-2)，即本测试独立实现的
#     「按 ' · ' 整段整段丢」。
#   （渲染出的页脚行 = 一个前导空格 + 提示串——前导空格来自 tui_render_footer 的
#    `printf ' %s'`；比较时把这一格算进去。core_fit 的右侧补齐空格在剥色后一并剥掉。）
# 帧规格：9 个视图 × 100×30（页脚放得下）+ 首页 × 46×22 与 30×20（放不下，两档截断深度），
# 共 11 帧。booking 是 main 新加的页，同样纳入这套字节级不变量。
t_begin "开/关底色只差两处已知变换（逐字节）"

B_WORK="$(mktemp -d)"
B_DUMP="${B_WORK}/dump_frames.sh"
# 一个进程渲染多帧（每帧前打印一行 '===FRAME view cols rows===' 作分隔），
# 免得每帧都付一次 source 全套 lib 的启动开销。用 <<'EOF' 原样写入，不展开变量。
# 参数：<root> <with_bg|no_bg> <specs...>；no_bg 模式在主题/图标/盒子初始化**之后**
# 把 UI_BG 置空、UI_RESET 退回纯 reset——这是「关底色」的唯一开关，之后帧里就不该再有
# 任何 UI_BG 字节（测试主体断言：与开底色帧只差那两处已知变换）。
cat > "${B_DUMP}" <<'DUMP_EOF'
#!/usr/bin/env bash
set -uo pipefail
root="$1"; mode="$2"; shift 2
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
if [[ "$mode" == "no_bg" ]]; then
  UI_BG=""
  UI_RESET="$(core_c_reset)"
fi
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

# 9 个视图各在 100×30（页脚放得下完整提示）比一次；首页另在 46×22 与 30×20 各比一次
# （放不下 → 走「按 ' · ' 整段丢弃」的截断，两档深度），共 11 帧。
B_VIEWS=(home assignments schedule classrooms grades exams public booking settings)
B_SPECS=()
for b_v in "${B_VIEWS[@]}"; do B_SPECS+=("${b_v}" 100 30); done
B_SPECS+=(home 46 22 home 30 20)

# 两棵树都在 dark 主题下渲染（dump 脚本里写死 ui_theme_init dark），
# 所以「本主题底色」就是当前 dark 的 UI_BG；为空则两种变换都退化成恒等，断言会立刻红。
ui_theme_init dark
icon_init
ui_box_init
B_THEME_BG="${UI_BG}"
assert_ok test -n "${B_THEME_BG}"

# 产品默认页脚提示串：本测试**写死的完整串**。它必须与 tui.sh 里那一条逐字相同
# （见下面的源码级断言）——否则谁改了实现却没改测试，立刻红。
# 放得下时渲染出的页脚就是它；放不下时由 b_expect_footer 独立截断得到期望值。
B_DEFAULT_HINT='↑↓ 选择 · Enter 进入 · Esc 返回 · q 退出 · Tab 切换 · r 刷新 · c 设置'

# 两种已知变换（规则写死在函数体里，一眼能看出「只承认这两处」）。
# 变换 a：关底色行里每个裸 \033[0m → \033[0m + 本主题底色（这正是 UI_RESET 的定义）。
b_bg_after_reset() {
  local s="${1:-}" out=""
  while [[ "${s}" == *$'\033[0m'* ]]; do
    out+="${s%%$'\033[0m'*}"$'\033[0m'"${B_THEME_BG}"
    s="${s#*$'\033[0m'}"
  done
  B_NORM="${out}${s}"
}

# 变换 b：开底色帧第 1 行多出的那一次底色发送（**必须**紧贴 \033[2J）。
# B_STRIPPED=1 表示这一帧确实发过底色；=0 表示没发（那就是「擦屏处露出终端底色」的真实
# 回归，调用方必须判红——注意此时本函数是**恒等映射**，逐行比较**发现不了**，所以必须单列标志）。
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

# 同一棵树、同一批帧规格，渲染「开底色」与「关底色」两份输出。
bash "${B_DUMP}" "${BUPTY_HOME}" with_bg "${B_SPECS[@]}" > "${B_WORK}/bg.txt"
bash "${B_DUMP}" "${BUPTY_HOME}" no_bg   "${B_SPECS[@]}" > "${B_WORK}/nobg.txt"
b_split_frames "${B_WORK}/bg.txt"   "${B_WORK}/bg"
b_split_frames "${B_WORK}/nobg.txt" "${B_WORK}/nobg"

# 源码级：产品默认提示串必须**逐字等于**本测试写死的 B_DEFAULT_HINT。
# （tui.sh 那一行形如：`[[ -n "${hint}" ]] || hint="<默认串>"`；取 `hint="` 之后到行尾引号的内容。）
b_impl_hint="$(grep -F 'hint="↑↓ ' "${BUPTY_HOME}/tui.sh" | head -n1)"
b_impl_hint="${b_impl_hint#*hint=\"}"
b_impl_hint="${b_impl_hint%\"}"
assert_eq "${b_impl_hint}" "${B_DEFAULT_HINT}" \
  "tui.sh 的默认页脚提示串必须逐字等于测试写死的 B_DEFAULT_HINT"

b_frames=0          # 实际比较的帧数（必须等于帧规格数）
b_same_frames=0     # bg 帧与 no_bg 帧完全相同的帧数（必须为 0：否则不变量是空集真命题）
b_diff_lines=0      # 做完变换 a/b 后仍不同的行数（必须为 0）
b_linecount_bad=0   # bg 与 no_bg 行数不一致的帧数（必须为 0）
b_overflow_bad=0    # 任一行显示宽度 > UI_COLS 的帧数（必须为 0）
b_a_applied=0       # 变换 a 真的改写了多少行的字节（0 = 变换是恒等，等于没在做归一化）
b_b_applied=0       # 变换 b 真的摘掉了多少次帧首底色（0 = 同上）
b_b_missing=0       # 帧首**没**发底色的帧数（必须为 0；这一项不能靠逐行比较发现）
b_footer_bad=0      # 页脚 != 独立算出的 EXPECTED 的帧数（必须为 0）
b_fits_seen=0       # 页脚「放得下」分支实际生效的帧数（防规则退化成空集真命题）
b_trunc_seen=0      # 页脚「整段截断」分支实际生效的帧数

for bgf in "${B_WORK}"/bg/*; do
  b_frames=$((b_frames + 1))
  mapfile -t bg_lines < "${bgf}"
  mapfile -t nb_lines < "${B_WORK}/nobg/$(basename "${bgf}")"
  n=${#bg_lines[@]}

  # 两帧行数必须相等（这是「同树自比」不依赖固定行数的前提）。
  if (( n != ${#nb_lines[@]} )); then
    b_linecount_bad=$((b_linecount_bad + 1))
    printf 'FAIL [%s] 第 %s 帧：开底色 %s 行 != 关底色 %s 行\n' \
      "${TESTS_NAME}" "${b_frames}" "${n}" "${#nb_lines[@]}"
    continue
  fi

  # 非空集验证：两帧必须**确实不同**；相同则这条不变量恒真、什么都没验。
  if [[ "${bg_lines[*]}" == "${nb_lines[*]}" ]]; then
    b_same_frames=$((b_same_frames + 1))
    printf 'FAIL [%s] 第 %s 帧：开底色与关底色输出完全相同（不变量成了空集真命题）\n' \
      "${TESTS_NAME}" "${b_frames}"
  fi

  # 帧标记行（第 0 行）里带着这帧的列数——页脚预算由它算，不写死。
  b_marker="${bg_lines[0]#===FRAME }"; b_marker="${b_marker%===}"
  read -r b_view b_cols b_rows <<< "${b_marker}"
  assert_ok test -n "${b_cols}"

  # ---- 逐行：宽度 ≤ UI_COLS，且关底色行做完变换 a/b 后与开底色行逐字节相同 ----
  for ((k = 1; k < n; k++)); do
    b_strip "${bg_lines[k]}"; _core_width "${B_PLAIN}"
    if (( _CORE_W > b_cols )); then
      b_overflow_bad=$((b_overflow_bad + 1))
      printf 'FAIL [%s] 第 %s 帧第 %s 行：显示宽度 %s > UI_COLS %s\n' \
        "${TESTS_NAME}" "${b_frames}" "$((k + 1))" "${_CORE_W}" "${b_cols}"
    fi

    # 变换 a 作用于**关底色**侧：每个裸 \033[0m 后补一次本主题底色。
    b_bg_after_reset "${nb_lines[k]}"; exp="${B_NORM}"
    if [[ "${nb_lines[k]}" != "${exp}" ]]; then b_a_applied=$((b_a_applied + 1)); fi

    cn="${bg_lines[k]}"
    if (( k == 1 )); then
      # 变换 b 只作用于开底色帧首行：摘掉那一次底色并置 B_STRIPPED 标志。
      b_strip_lead_bg "${cn}"; cn="${B_NORM}"
      if (( B_STRIPPED )); then
        b_b_applied=$((b_b_applied + 1))
      else
        # 帧首没发底色 → 变换 b 退化成恒等，逐行比较必然「相等」，必须靠这里判红。
        b_b_missing=$((b_b_missing + 1))
        printf 'FAIL [%s] 第 %s 帧帧首没有发出本主题底色（\\033[2J 会擦出终端原底色）\n' \
          "${TESTS_NAME}" "${b_frames}"
      fi
    fi
    if [[ "${cn}" != "${exp}" ]]; then
      b_diff_lines=$((b_diff_lines + 1))
      printf 'FAIL [%s] 第 %s 帧第 %s 行：开/关底色差异超出那两处已知变换（可能是真实回归）\n' \
        "${TESTS_NAME}" "${b_frames}" "$((k + 1))"
      printf '  no_bg→变换a/中: %q\n  with_bg      : %q\n' "${exp}" "${cn}"
    fi
  done

  # ---- 页脚：期望值由测试独立构造（写死的完整串 or 独立整段截断） ----
  b_strip "${bg_lines[-1]}"; cf="${B_PLAIN}"
  while [[ "${cf}" == *' ' ]]; do cf="${cf%' '}"; done
  b_exp="$(b_expect_footer "${B_DEFAULT_HINT}" "$((b_cols - 2))")"
  # 渲染出的页脚行 = 一个前导空格（tui_render_footer 的 `printf ' %s'`）+ 提示串。
  if [[ "${b_exp}" == "${B_DEFAULT_HINT}" ]]; then
    b_fits_seen=$((b_fits_seen + 1))
  else
    b_trunc_seen=$((b_trunc_seen + 1))
  fi
  if [[ "${cf}" != " ${b_exp}" ]]; then
    b_footer_bad=$((b_footer_bad + 1))
    printf 'FAIL [%s] 第 %s 帧（%s 列）页脚 != 独立算出的期望\n' \
      "${TESTS_NAME}" "${b_frames}" "${b_cols}"
    printf '  want: %q\n  got : %q\n' " ${b_exp}" "${cf}"
  fi
done

assert_eq "${b_frames}" "11" "应转储 11 帧（9 视图 × 100×30 + 首页 × 46×22 + 首页 × 30×20）"
assert_eq "${b_linecount_bad}" "0" "开/关底色两帧的行数必须相等"
assert_eq "${b_same_frames}" "0" \
  "每帧开/关底色都必须确实不同（相同 = 不变量成了空集真命题）"
assert_eq "${b_diff_lines}" "0" \
  "11 帧：关底色行做完那两处已知变换后必须与开底色行逐字节相同（超出即潜在回归）"
assert_eq "${b_overflow_bad}" "0" "任何一行的显示宽度都不得超过 UI_COLS"
assert_eq "${b_footer_bad}" "0" \
  "11 帧的页脚都必须等于测试独立算出的期望（放得下 = 写死的完整串；放不下 = 整段截断）"
assert_eq "${b_b_missing}" "0" "每一帧帧首都必须发出本主题底色（\033[2J 前必须有底色）"
# 变换必须真的在改写字节：否则「归一化」是恒等，逐行断言会静默地什么都没测。
assert_ok test "${b_a_applied}" -ge 1
assert_ok test "${b_b_applied}" -ge 1
# 页脚两条分支都得真的生效过，否则「全绿」可能是规则退化成空集真命题。
assert_ok test "${b_fits_seen}" -ge 1      # 100×30 的 9 帧确实放得下
assert_ok test "${b_trunc_seen}" -ge 2     # 46×22、30×20 两档确实走到了整段截断
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
  # B_RAW[0] 是状态行，B_RAW[1..6] 是块的 6 行。
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
# ---------------------------------------------------------------------------
# 7b. 版式顺序：页签条固定在状态行正下方（大块之上），不许插到中间去
# ---------------------------------------------------------------------------
# 用户 2026-10-14 定的版式：状态行 / 页签条 / 大块 / 正文。这里对**整帧**逐行剥色后
# 钉死前三者的行号——顺序错了（比如页签条又跑到块下面）必须让本用例变红。
# 负向对照：把「页签条在第 3 行」写成第 9 行必须失败，证明断言真的在量顺序。
# 下面是**整帧**（tui_render）的行号，把「页签条插在中间」这个 bug 钉成红灯：
#   下标 0      状态行（页名 + 账号/+齿轮）
#   下标 1、3   分隔线
#   下标 2      页签条（紧贴状态行下方——固定位置）
#   下标 4..9   大块 6 行（只在首页）
t_begin "版式顺序：状态行 → 页签条 → 大块"
BUPTY_FORCE_BANNER=1 BUPTY_AMBIG_W=1 UI_COLS=100 UI_ROWS=30
HOME_FOCUS=grid HOME_SEL=0
b_full_frame
b_strip "${B_RAW[0]}"; b_row0="${B_PLAIN}"
b_strip "${B_RAW[2]}"; b_row2="${B_PLAIN}"
# 第 1 行是状态行：含页名，且**不含**任何签的正文（签全在第 3 行）。
assert_eq "$(printf '%s' "${b_row0}" | grep -c '首页')" "1" "第 1 行必须是状态行（含页名「首页」）"
case "${b_row0}" in
  *作业*) assert_eq "状态行混进了页签内容" "" "状态行不得含页签正文「作业」" ;;
  *) assert_eq "ok" "ok" "状态行不含页签正文「作业」" ;;
esac
# 第 3 行（下标 2）是页签条：9 个签必须全在这一行。
b_row2_bad=0
for b_lab in "${TUI_TAB_LABELS[@]}"; do
  case "${b_row2}" in
    *"${b_lab}"*) ;;
    *) b_row2_bad=$((b_row2_bad + 1))
       printf 'FAIL [%s] 页签条缺签「%s」：%s\n' "${TESTS_NAME}" "${b_lab}" "${b_row2}" ;;
  esac
done
assert_eq "${b_row2_bad}" "0" "第 3 行必须是完整页签条（9 个签都在）"
# 大块首行必须落在第 5 行（下标 4）：状态 1 + 分隔 1 + 页签 1 + 分隔 1 = 4 行 chrome 在其上。
# 块每行都是「左留白 floor((UI_COLS-47)/2) + 47 列」，与 banner_render 的产出逐字相同——
# 拿**渲染出来的块本身**做参照：第 5 行的左留白必须与它一致，且不得是页签条/分隔线。
b_strip "${B_RAW[4]}"
assert_eq "$(b_leading_spaces "${B_PLAIN}")" "$(( (UI_COLS - BANNER_W) / 2 ))" \
  "第 5 行必须是块的首行（左留白 = floor((UI_COLS-47)/2)）"
b_banner_render_matches() {
  local i line bpad got
  banner_render "${UI_ACCENT}"
  bpad=$(( (UI_COLS - BANNER_W) / 2 ))
  (( bpad < 0 )) && bpad=0
  for ((i = 0; i < BANNER_H; i++)); do
    b_strip "${BANNER_ROWS[$i]}"
    line="${B_PLAIN}"
    b_strip "${B_RAW[$((4 + i))]}"
    got="${B_PLAIN:bpad}"
    [[ "${got:0:BANNER_W}" == "${line}" ]] || {
      printf '  block row %s: got[%s] want[%s]\n' "$i" "${got:0:BANNER_W}" "${line}" >&2
      return 1
    }
  done
  return 0
}
assert_ok b_banner_render_matches
# 反向对照：块的 6 行（4..9）里不得再出现页签正文——那正是用户报的「插在中间」。
b_tab_between=0
for k in 4 5 6 7 8 9; do
  b_strip "${B_RAW[$k]}"
  case "${B_PLAIN}" in
    *成绩*) b_tab_between=$((b_tab_between + 1)) ;;
  esac
done
assert_eq "${b_tab_between}" "0" "块的 6 行里不得混进页签条（「成绩」不得出现在第 5..10 行）"
unset BUPTY_FORCE_BANNER

# 7c. 大块只属于首页：BANNER_ACTIVE 是首页专属状态，换视图后必须不许残留
# ---------------------------------------------------------------------------
# 这是拆分 tui_render_header 时踩到的真缺陷：判据若直接读 BANNER_ACTIVE，先渲染一帧首页
# 把它置 1，再切到课表，课表也会照画 6 行 BUPTY（块塌成空行，帧高不变量照样通过）。
# 判据必须走 chrome 口径（base = chrome - 页签条 > 5）。这里先渲染首页把状态置脏，
# 再渲染非首页，断言块的首行字形**不出现**在帧里。
t_begin "大块不残留：首页渲染过之后切到课表不得再画块"
BUPTY_FORCE_BANNER=1 BUPTY_AMBIG_W=1 UI_COLS=100 UI_ROWS=30
TUI_VIEW=home HOME_FOCUS=grid HOME_SEL=0
TUI_FRAME_FILE="$(mktemp)"; tui_render >/dev/null; rm -f "${TUI_FRAME_FILE}"
assert_eq "${BANNER_ACTIVE}" "1" "前置条件：首页这一帧确实把 BANNER_ACTIVE 置成 1"
# 块首行的字形（用产品自己的翻译函数取，别在这里复刻映射表）。
_banner_translate "$(banner_plain_row 0)"
b_block_line="${_BANNER_TEXT}"
b_leak=0
for v in assignments schedule classrooms grades exams public booking settings; do
  TUI_VIEW="${v}"
  UI_COLS=100 UI_ROWS=30
  TUI_FRAME_FILE="$(mktemp)"
  b_vf="$(tui_render)"
  rm -f "${TUI_FRAME_FILE}"
  if printf '%s' "${b_vf}" | grep -qF "${b_block_line}"; then
    b_leak=$((b_leak + 1))
    printf 'FAIL [%s] 视图 %s 的帧里出现了大块首行（BANNER_ACTIVE 残留）\n' "${TESTS_NAME}" "${v}"
  fi
done
assert_eq "${b_leak}" "0" "非首页视图的帧里不得出现大字符块（首页状态不得外溢）"
# 反向对照：同一段检测对**首页**必须命中，证明它不是恒不报。
TUI_VIEW=home
TUI_FRAME_FILE="$(mktemp)"; b_hf="$(tui_render)"; rm -f "${TUI_FRAME_FILE}"
assert_eq "$(printf '%s' "${b_hf}" | grep -cF "${b_block_line}")" "1" \
  "负向对照：首页的帧里必须命中一次块首行（否则上面的检测恒真）"
unset BUPTY_FORCE_BANNER

# ---------------------------------------------------------------------------
# 8. chrome 行数（唯一口径）
# ---------------------------------------------------------------------------
# base 恒等于「不含页签条」的行数：非 home = 5（顶栏 1 + 分隔 1 + 页脚 3），
# home 且出块 = 11（状态行 1 + 块 6 + 分隔 1 + 页脚 3）。页签条放得下时整条 +2
# （页签条 1 行 + 它下面那条分隔线 1 行）→ 13 / 7；任一子句不满足则 +0，回到 11 / 5。
t_begin "chrome 行数：base 11/5，页签条 +2 → 13/7"
BUPTY_FORCE_BANNER=1 BUPTY_AMBIG_W=1 UI_COLS=100 UI_ROWS=30
banner_chrome_rows home
assert_eq "${BANNER_CHROME_ROWS}" "13" "首页出块 + 页签条 → chrome 13（base 11 + 页签条 2）"
assert_eq "${BANNER_TABBAR_ROWS}" "2" "100×30 下页签条放得下 → 贡献 2 行"
# 任意非 home 视图 base 一律 5，+ 页签条 2 → 7（即便块本可显示）。
for v in assignments schedule classrooms grades exams public booking settings; do
  banner_chrome_rows "${v}"
  assert_eq "${BANNER_CHROME_ROWS}" "7" "视图 ${v} → chrome 7（base 5 + 页签条 2）"
done
# 省略视图名时取当前视图 TUI_VIEW。
TUI_VIEW=assignments; banner_chrome_rows
assert_eq "${BANNER_CHROME_ROWS}" "7" "省略参数时取 TUI_VIEW=assignments → 7"
TUI_VIEW=home; banner_chrome_rows
assert_eq "${BANNER_CHROME_ROWS}" "13" "省略参数时取 TUI_VIEW=home（块开）→ 13"

# ---- 宽度子句的边界两侧：页签串宽度 + 左右各 1 格留白 <= UI_COLS 才显示 ----
# 独立算出页签串宽度：TUI_TAB_LABELS 按顺序、签间两个空格相接（加左右留白各 1）。
b_tw=0
for ((i = 0; i < ${#TUI_TAB_LABELS[@]}; i++)); do
  _core_width "${TUI_TAB_LABELS[$i]}"; b_tw=$((b_tw + _CORE_W))
  if (( i > 0 )); then b_tw=$((b_tw + 2)); fi
done
assert_eq "${b_tw}" "54" "9 个签（首页…设置）+ 签间空格的显示宽度必须是 54"
b_wthresh=$((b_tw + 2))
assert_eq "${b_wthresh}" "56" "宽度门槛 = 页签串 54 + 左右留白 2 = 56"
# 高度给足（30 行），只让宽度子句决定；用非 home（base=5）隔离出页签条那 2 行。
BUPTY_FORCE_BANNER=0 UI_ROWS=30
UI_COLS="${b_wthresh}"; banner_chrome_rows assignments
assert_eq "${BANNER_TABBAR_ROWS}" "2" "${b_wthresh} 列恰好放得下 → 显示页签条（边界取等号）"
assert_eq "${BANNER_CHROME_ROWS}" "7" "放得下时 chrome = base 5 + 2"
UI_COLS=$((b_wthresh - 1)); banner_chrome_rows assignments
assert_eq "${BANNER_TABBAR_ROWS}" "0" "$((b_wthresh - 1)) 列差 1 列 → 整条页签条（含下线）隐藏"
assert_eq "${BANNER_CHROME_ROWS}" "5" "放不下时 chrome 回到 base 5"

# ---- 高度子句的边界两侧：UI_ROWS - base - 2 >= BANNER_TABBAR_MIN_BODY 才显示 ----
# 门槛 12 是产品实测出来的「任何页显示页签条后仍不顶穿帧高」的最小正文预算；
# 这里把它钉住（改小会让页签条在极矮窗里顶穿），并用它推门槛行数。
assert_eq "${BANNER_TABBAR_MIN_BODY}" "12" "页签条高度门槛 BANNER_TABBAR_MIN_BODY 必须为 12"
UI_COLS=100                       # 宽度给足，避开宽度子句
# 非 home base=5 → 门槛行数 = 5 + 2 + 12 = 19。
b_nh_rows=$((5 + 2 + 12))
UI_ROWS="${b_nh_rows}"; banner_chrome_rows assignments
assert_eq "${BANNER_TABBAR_ROWS}" "2" "${b_nh_rows} 行恰好够正文 → 显示页签条（边界取等号）"
assert_eq "${BANNER_CHROME_ROWS}" "7" "非 home 显示页签条 → 7"
UI_ROWS=$((b_nh_rows - 1)); banner_chrome_rows assignments
assert_eq "${BANNER_TABBAR_ROWS}" "0" "$((b_nh_rows - 1)) 行差 1 行 → 隐藏页签条"
assert_eq "${BANNER_CHROME_ROWS}" "5" "隐藏时 chrome 回到 base 5"
# 首页出块 base=11 → 门槛行数 = 11 + 2 + 12 = 25。
BUPTY_FORCE_BANNER=1
b_h_rows=$((11 + 2 + 12))
UI_ROWS="${b_h_rows}"; banner_chrome_rows home
assert_eq "${BANNER_CHROME_ROWS}" "13" "首页出块：${b_h_rows} 行恰好够正文 → 13（边界取等号）"
UI_ROWS=$((b_h_rows - 1)); banner_chrome_rows home
assert_eq "${BANNER_CHROME_ROWS}" "11" "首页出块：$((b_h_rows - 1)) 行差 1 行 → 退回 base 11"

# 高度子句的目的：页签条显示后帧高不得顶穿 UI_ROWS。在非 home 门槛行数上对每个页签实测。
# （门槛正是为「任意页都不顶穿」而取各视图最大值的，这里验证它确实做得到。）
b_fit_bad=0
UI_ROWS="${b_nh_rows}" UI_COLS=100 BUPTY_FORCE_BANNER=0
for v in "${TUI_TABS[@]}"; do
  TUI_VIEW="${v}"
  banner_chrome_rows "${v}"
  (( BANNER_TABBAR_ROWS > 0 )) || continue
  TUI_FRAME_FILE="$(mktemp)"
  frame="$(tui_render)"; rm -f "${TUI_FRAME_FILE}"
  # 行数要数**帧里真实的行**：命令替换会吃掉末尾换行，所以不能用
  # `printf '%s\n' "${frame}" | wc -l`（多算 1 行），也不能用 `grep -c ''`（同样多算 1）。
  # 补一个哨兵再数 −1，正好还原。
  nlines=$(printf '%s\n' "${frame}" | wc -l | tr -d '[:space:]')
  nlines=$(( nlines - 1 ))
  if (( nlines > UI_ROWS )); then
    b_fit_bad=$((b_fit_bad + 1))
    printf 'FAIL [%s] 页签条显示时 %s 页在 %s 行下帧高 %s > UI_ROWS\n' \
      "${TESTS_NAME}" "${v}" "${UI_ROWS}" "${nlines}"
  fi
done
assert_eq "${b_fit_bad}" "0" "页签条显示时任何页的帧高都不得超过 UI_ROWS"
TUI_VIEW=home

# 块关时首页退回 base 5（+ 页签条）。
BUPTY_FORCE_BANNER=0 UI_COLS=100 UI_ROWS=30; banner_chrome_rows home
assert_eq "${BANNER_CHROME_ROWS}" "7" "首页块关 → base 5 + 页签条 2 = 7"
unset BUPTY_FORCE_BANNER
# 未设置且宽度门槛不满足时：46 列放不下页签条（56 > 46）→ base 5。
UI_COLS=46 UI_ROWS=30; banner_chrome_rows home
assert_eq "${BANNER_CHROME_ROWS}" "5" "46 列（<56）放不下页签条 → 首页 chrome 5"
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
