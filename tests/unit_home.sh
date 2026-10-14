#!/usr/bin/env bash
# tests/unit_home.sh —— 首页模块网格的几何单测（对应 lib/views/home.sh）
#
# 本文件不强制多字节模式：它断言的是**与边框字形无关的不变量**——
# 「每行恰好铺满」「卡片分栏列位置恒定」（仅栅格档位 A/B/C；档位 D 是纵向列表，
# 信息列在放不下时按设计整段省略，各行本就不同宽）。两种模式下都必须全绿：
#   * 字符模式（BUPTY_MB=1）：amb=1 → Unicode 边框（┌─┐），▶ 与 ─ 同为 1 列
#   * 字节模式（BUPTY_MB=0）：core_utf8 假 → 边框退 ASCII（+-|）
#   * amb=2（CJK 终端）：ICON_UNICODE_W=2 → ui_box_init 退 ASCII 边框，
#     而 ▶(U+25B6) 是真歧义类实占 2 列 ← 曾经的破绽就在这里
#
# 回归目标（真实存在过的 bug，已在真终端配置下复现过）：
#   档位 A 选中卡片的顶边曾写死「▶ 之后 IW-2 根横线」，等价于假设 w(▶)==w(横线)。
#   该假设在「ASCII 边框 + amb=2」下不成立（1 ≠ 2），于是选中卡片顶边宽 1 列，
#   79 列终端上整行渲染成 80 列，第 3 行顶出右边界。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 隔离配置目录：避免读到开发者本机已保存的主题，保证结果可复现。
export XDG_CONFIG_HOME="$(mktemp -d)"
trap 'rm -rf "${XDG_CONFIG_HOME}"' EXIT

# 本文件只钉「降级路径」的几何：块关闭时 chrome 固定（banner_chrome_rows：5 + 页签条 2）。
# 块是否显示取决于 core_utf8（即 locale）：本机 Git Bash 是非 UTF-8（块自然关），
# 而 WSL/LANG=C.UTF-8 下 core_utf8 为真、BUPTY_AMBIG_W=1，宽且够高时块会**自行打开**，
# chrome 从 7 涨到 13，同一个 (UI_COLS, UI_ROWS) 于是在两种 locale 下落到不同档位
# ——同一份断言结论相反。为了可复现，这里显式钉住 BUPTY_FORCE_BANNER=0（计划里
# 「测试环境下块默认关闭」的那条性质），让本文件永远只测降级路径。
# 块启用后的行为由 task B 的独立测试覆盖，不在这里断言。
export BUPTY_FORCE_BANNER=0

# tui.sh 自己会 `set -euo pipefail`，而本测试靠断言计数判定成败，必须自己控制失败处理：
# 载入后立刻关掉 errexit（与 tests/unit_responsive.sh 同一约定）。
# 不关的话 render_home 的**合法**返回码 1 会把整个测试静默杀掉——它末行是
# `(( r == 0 )) && printf '\n'`，第二行取假即返回 1（生产侧用 tui.sh:244
# 的 `render_${TUI_VIEW} || true` 兜住，见 lib/views/home.sh）。
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tui.sh"
set +e
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

ui_size() { :; }
creds_exists() { return 1; }

# ---------------------------------------------------------------------------
# 测试专用小工具
# ---------------------------------------------------------------------------

_H_LINES=()
_H_WIDTHS=()

# 去掉 ANSI 转义（只处理 CSI：ESC [ 参数 字母）。
# 刻意不写 ${s//$'\033'\[[0-9;]*[a-zA-Z]/} —— bash 的 * 是贪婪的，
# 那样写会从第一个转义一路删到行尾，量出来恒为 0，测试会「静默地永远通过」。
h_strip_ansi() {
  local s="$1" out=""
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"
    s="${s#*$'\033['}"
    s="${s#*[a-zA-Z]}"
  done
  printf '%s%s' "${out}" "${s}"
}

# 一行的显示列数。
h_width() {
  _core_width "${1:-}"
  printf '%s' "${_CORE_W}"
}

# 渲染一帧首页到 _H_LINES（每行已去转义）与 _H_WIDTHS（每行显示列数）。
# 一帧只渲染一次，宽度与分栏两项检查共用同一份输出，避免两次渲染不一致。
h_frame() {
  local line
  _H_LINES=()
  _H_WIDTHS=()
  while IFS= read -r line; do
    line="$(h_strip_ansi "${line}")"
    _H_LINES+=("${line}")
    _H_WIDTHS+=("$(h_width "${line}")")
  done < <(render_home)
}

# 所有非空行宽度是否一致（一致是网格的基本不变量）。
# 一致 → _H_COMMON 为公共宽度、_H_BAD 为空；否则 _H_BAD 描述异常行。
# 这个判据与多字节模式无关，且能抓到本次回归：选中卡片宽 1 列时，
# 只有顶边那一行会变宽，于是「各行等宽」立刻不成立。
h_uniform() {
  local i w="" out=""
  for i in "${!_H_WIDTHS[@]}"; do
    ((_H_WIDTHS[i] == 0)) && continue
    if [[ -z "${w}" ]]; then
      w="${_H_WIDTHS[i]}"
    elif ((_H_WIDTHS[i] != w)); then
      out+="${out:+ }$((i + 1)):${_H_WIDTHS[i]}"
    fi
  done
  _H_COMMON="${w}"
  if [[ -n "${out}" ]]; then _H_BAD="异常行 ${out}（首行 ${w} 列）"; else _H_BAD=""; fi
}

# 是否有行超出 limit 列。
h_overflow() {
  local limit="$1" i out=""
  for i in "${!_H_WIDTHS[@]}"; do
    ((_H_WIDTHS[i] > limit)) && out+="${out:+ }$((i + 1)):${_H_WIDTHS[i]}"
  done
  printf '%s' "${out}"
}

# 按 amb 忠实复现真实启动流程的推导链。
# 注意 ui_box_init 没有幂等哨兵（不像 icon_init 有 _ICON_INITIALIZED）：它两个分支都
# 显式赋值，本身就是可重复调用的，所以这里只需重置 icon 侧的状态。
# 它判定 Unicode/ASCII 边框看的是 BUPTY_AMBIG_W（不是 ICON_UNICODE_W），见 lib/ui.sh。
h_set_amb() {
  local amb="$1"
  BUPTY_AMBIG_W="${amb}"
  if ((amb == 2)); then export BUPTY_FORCE_ICONS=bg; else export BUPTY_FORCE_ICONS=half; fi
  _ICON_INITIALIZED=""
  icon_init
  ui_box_init
}

# 把数组按空格拼成一个串，便于 assert_eq 比对。
h_join() {
  local out="" x
  for x in "$@"; do out+="${out:+ }${x}"; done
  printf '%s' "${out}"
}

# 渲染一帧首页的**原始**行（保留 ANSI 转义）到 _H_RAW。
# 与 h_frame 的区别：h_frame 剥掉转义只留可见文本（量宽用），这里要的正是转义本身
# ——检查选中卡片有没有漏出「不属于本主题底色的」背景序列。
h_frame_raw() {
  local line
  _H_RAW=()
  while IFS= read -r line; do
    _H_RAW+=("${line}")
  done < <(render_home)
}

# 本主题 UI_BG 的 256 色索引（如 dark 的 233）。UI_BG 形如 $'\033[48;5;233m'。
# 从 UI_BG 本身反解，不写死数字：换主题后本断言自动跟着走。
h_ui_bg_index() {
  local s="${UI_BG#*48;5;}"
  printf '%s' "${s%%m*}"
}

# 帧内**所有**出现过的背景色索引（去重、按首次出现顺序）拼成的串。
#
# 口径（本轮重写）：整屏铺底之后，帧里合法地满是 `48;5;`——但**只允许本主题 UI_BG 的
# 那一个索引**。出现任何别的背景索引（无论来自 UI_HL_FG 误用、还是别处的游离背景）都
# 判为泄漏。原 bug 的形式恰恰就是「一个不属于底色的索引漏在文字区」，所以收窄到
# 「只准 UI_BG 索引」照样抓得住，不是放宽。
#
# 重要：本检查必须在 half/off 图标档位下进行——bg 模式图标**合法地**用背景色铺点阵
# （lib/icons.sh 的 _icon_render_bg），它自己的 48;5; 会被误报成卡片文字区的泄漏。
# 颜色泄漏与终端宽度无关，所以调用方把图标单独钉在 half，不跟随 h_set_amb 的档位。
h_bg_indices() {
  local i line idx out=""
  for i in "${!_H_RAW[@]}"; do
    line="${_H_RAW[i]}"
    while [[ "${line}" == *"48;5;"* ]]; do
      line="${line#*48;5;}"
      idx="${line%%[!0-9]*}"
      [[ -z "${idx}" ]] && break
      [[ " ${out} " == *" ${idx} "* ]] || out+="${out:+ }${idx}"
    done
  done
  printf '%s' "${out}"
}

# _H_LINES（当前帧、已去 ANSI）里 <needle> 出现的总次数 → _H_CNT。
# 用逐段剥离（不写 ${s//needle/} 也不写 grep）：前者算不了次数，后者要 fork。
# needle 一律用单字符字面量（'…' / '▶' / '▸'），两种多字节语义下都按字节匹配，安全。
h_count_char() {
  local needle="$1" i line tmp n=0
  for i in "${!_H_LINES[@]}"; do
    line="${_H_LINES[i]}"
    tmp="${line}"
    while [[ "${tmp}" == *"${needle}"* ]]; do
      n=$((n + 1))
      tmp="${tmp#*"${needle}"}"
    done
  done
  _H_CNT="${n}"
}

# 装饰卡框的帧级签名 → _H_DECOR_SIG：把当前帧里**含 '…' 的行**按顺序拼起来，
# 并做一次「选中标记归一」（▶→▸）。
# 为什么归一：装饰框所在的行通常还并排着真卡 6（3+3+1 的末行），选中卡 6 时它自己的
# 焦点标记会从 ▸ 变 ▶——那是**真卡**的合法选中效果，不是装饰框的变化。归一掉它，剩下的
# 任何逐字节差异都只能来自装饰框本身。档位 A 的 '…' 行落在图标卡的内容行（没有标记），
# 归一恰好是空操作。
h_decor_sig() {
  local i line out=""
  for i in "${!_H_LINES[@]}"; do
    line="${_H_LINES[i]}"
    case "${line}" in
      *'…'*) out+="${line//▶/▸}"$'\n' ;;
    esac
  done
  _H_DECOR_SIG="${out}"
}

# '…' 行里「第一个 '…' 之后」的全部内容里有没有 ▶/▸ → _H_DECOR_TAIL_MARK（0/1）。
# 该行从第一个 '…' 起往右全是装饰框（'…' 属于第 1 个装饰框；3+3+1 与档位 C 的末行里，
# 真卡 6 在装饰框**之前**，它内部不含 '…'）。所以这段尾巴里出现标记，只可能是装饰框自己
# 被选中了——真卡 6 的标记永远在第一个 '…' 左边，被这个切法排除在外。
h_decor_tail_mark() {
  local i line tail
  _H_DECOR_TAIL_MARK=0
  for i in "${!_H_LINES[@]}"; do
    line="${_H_LINES[i]}"
    case "${line}" in
      *'…'*)
        tail="${line#*…}"
        case "${tail}" in *'▶'*|*'▸'*) _H_DECOR_TAIL_MARK=1 ;; esac
        ;;
    esac
  done
}

ui_theme_init

# ---------------------------------------------------------------------------
# 0. 反向对照：证明本文件的断言「失败得出来」
# ---------------------------------------------------------------------------
# 前面踩过坑：一条恒真的断言会让整份测试静默全绿。先拿一条**故意做错**的行
# 喂进同一条量宽链路，确认它真的会被量出超宽、判为溢出。
t_begin "反向对照"
UI_COLS=40
assert_eq "$(h_width "$(printf '%*s' "$((UI_COLS + 1))" '')")" "41" \
  "刻意超宽一行必须量出 41 列（否则量宽链路是坏的）"
assert_eq "$(( $(h_width "$(printf '%*s' "$((UI_COLS + 1))" '')") > UI_COLS ))" "1" \
  "该行必须被判为溢出"
assert_eq "$(h_width '正常一行')" "8" "正常行量宽必须准确"

# ---------------------------------------------------------------------------
# 1. 档位选择：A / B / C / D 的阈值
# ---------------------------------------------------------------------------
t_begin "档位阈值"
# 新版阶梯（lib/views/home.sh 的 _home_layout，阈值全部从几何反推）：
#   A  UI_COLS>=79 且 body>=26   7 张图标卡，3+3+1 = 26 行
#   B  UI_COLS>=79 且 body>=16   前 3 张图标卡 + 后 4 张迷你卡，仍是 3+3+1 = 16 行
#   C  UI_COLS>=40 且 body>=15   7 张迷你卡 2 列 × 4 行 = 15 行
#   D  其余                      1 列列表（7 行滑动窗口）
# 取满足条件的最高档。**注意档位字母全体后移了一位**：旧版「C」= 现在的「D」（列表）。
#
# 阈值边界一律用 `_home_layout <body>` **显式喂 body** 来钉：不经过 banner_chrome_rows，
# 阈值就不会被「页签条要不要占 2 行」的高度门槛搅进来，每条断言只测一个变量。
for spec in "79 26 A" "79 25 B" "79 16 B" "79 15 C" "40 15 C" "40 14 D" "78 26 C" "39 26 D" "79 0 D"; do
  read -r cols body tier <<< "${spec}"
  UI_COLS="${cols}"
  _home_layout "${body}"
  assert_eq "${_HOME_TIER}" "${tier}" "cols=${cols} body=${body} → 档位 ${tier}"
done

# _HOME_COLS 随档位：3+3+1 的 A/B 是 3 列、C 是 2 列、D 是 1 列。
UI_COLS=79; _home_layout 26; assert_eq "${_HOME_COLS}" "3" "A 档单行最多 3 格"
UI_COLS=79; _home_layout 16; assert_eq "${_HOME_COLS}" "3" "B 档单行最多 3 格"
UI_COLS=40; _home_layout 15; assert_eq "${_HOME_COLS}" "2" "C 档单行最多 2 格"
UI_COLS=24; _home_layout 15; assert_eq "${_HOME_COLS}" "1" "D 档单行最多 1 格"

# 与 chrome 的耦合（banner_chrome_rows 唯一口径）：BUPTY_FORCE_BANNER=0 时 chrome = 5，
# 页签条够宽够高时再加 2，body = UI_ROWS - chrome。钉住几条真实尺寸的整链推导，
# 免得 _home_layout 的 body 口径哪天和 banner_chrome_rows 脱节还不自知。
for spec in "79 24 B" "79 33 A" "40 24 C" "24 24 D"; do
  read -r cols rows tier <<< "${spec}"
  UI_COLS="${cols}" UI_ROWS="${rows}"
  _home_layout
  assert_eq "${_HOME_TIER}" "${tier}" "cols=${cols} rows=${rows}（经 chrome 推导）→ 档位 ${tier}"
done

# ---------------------------------------------------------------------------
# 2. 栅格档位 A / B：卡片几何与分栏列位置（本次回归的核心）
# ---------------------------------------------------------------------------
# 渲染一帧约 2.6s（每帧 icon_render 要 12 次 fork），矩阵刻意收窄：
#   cols 取 79（三张卡恰好放下的边界，本次回归的现场）与 120（宽终端补边）；
#   rows 取 33（chrome7 → body26 → 档位 A：7 张全图标卡 = 26 行）与 24（chrome7 → body17
#     → 档位 B：行 2/行 3 降级成迷你卡 = 16 行）——两档共用同一个 3+3+1 栅格；
#   sel 取 0/1/5（第一行首卡、同行邻卡、第二行末卡）——六张卡几何同构，
#   而回归只对「被选中的那一张」生效，覆盖到每个位置一次即可。
for amb in 1 2; do
  h_set_amb "${amb}"
  for spec in "79 33 A 26" "120 33 A 26" "79 24 B 16" "120 24 B 16"; do
    read -r cols rows tier want_lines <<< "${spec}"
    UI_COLS="${cols}"
    UI_ROWS="${rows}"
    _home_layout
    t_begin "档位${tier} amb=${amb} cols=${cols}"
    assert_eq "${_HOME_TIER}" "${tier}" "${cols} 列 × ${rows} 行应为档位 ${tier}"

    # 3+3+1 栅格的几何：三个 25 列卡片 + 两个 2 列间隙 = 79 列，整体居中 →
    # 行宽恒为 pad + 79（卡片尺寸固定，不随终端拉伸）。
    pad=$(((cols - 79) / 2))
    want_w=$((pad + 79))

    for sel in 0 1 5; do
      HOME_FOCUS="grid"
      HOME_SEL="${sel}"
      h_frame
      # 1) 各行必须等宽——选中卡片宽 1 列时只有顶边那一行会变宽，这里立刻露馅。
      h_uniform
      assert_eq "${_H_BAD}" "" "sel=${sel} 所有非空行等宽"
      # 2) 公共宽度必须精确等于 pad+79 —— 把每张卡片钉死在 25 列。
      assert_eq "${_H_COMMON}" "${want_w}" "sel=${sel} 行宽恒为 pad+79"
      # 3) 不得顶出右边界。
      assert_eq "$(h_overflow "${cols}")" "" "sel=${sel} 无行超出 ${cols} 列"
      # 4) 末行补的装饰框不得改变总行数（A=26 行、B=16 行）。
      assert_eq "${#_H_LINES[@]}" "${want_lines}" "sel=${sel} 帧行数恒为 ${want_lines}（装饰框不占额外行）"
    done
  done
done

# ---------------------------------------------------------------------------
# 3. 档位 B / C：任何一行都不得超出 UI_COLS，帧高不得超正文
# ---------------------------------------------------------------------------
# 显式钉住 amb：下面的期望值不依赖上一节循环结束时的残留状态。
h_set_amb 2
for wh in "40 24" "78 22" "79 16" "24 24" "16 12" "100 14"; do
  read -r cols rows <<< "${wh}"
  UI_COLS="${cols}" UI_ROWS="${rows}"
  _home_layout
  t_begin "档位${_HOME_TIER} cols=${cols} rows=${rows}"
  for sel in 0 5; do
    HOME_FOCUS="grid"
    HOME_SEL="${sel}"
    h_frame
    # 「各行等宽」只对栅格档位（A/B/C）成立：档位 D 走 _home_render_list（1 列列表），
    # 信息列在预算不足时按设计整段省略，各行宽度本就该不同（窄终端尤其明显）。
    # 档位 C 的末行补上装饰框后恰好铺满两格，同样等宽，所以豁免的只有 D。
    if [[ "${_HOME_TIER}" != "D" ]]; then
      h_uniform
      assert_eq "${_H_BAD}" "" "sel=${sel} 所有非空行等宽"
    fi
    assert_eq "$(h_overflow "${cols}")" "" "sel=${sel} 无行超出 ${cols} 列"
    assert_eq "$(( ${#_H_LINES[@]} <= rows - 5 ))" "1" "帧高 <= UI_ROWS-5"
  done
done

# ---------------------------------------------------------------------------
# 3b. 极窄 / 极矮兜底
# ---------------------------------------------------------------------------
# 档位 C 是 UI_COLS < 40 的兜底档，代码里没有任何宽度/高度下限，
# 因此下面这两条不变量只能靠它自己撑住。两处都真实溢出过：
#   * 只剩 1 列时，选中标记 ▶(U+25B6) 在 amb=2 下实占 2 列——只截断名字、
#     保留标记，整行就恒为 2 列（名字截断分支里又漏了「标记自己放不下」这一档）。
#   * UI_ROWS <= 5 时正文预算为 0 或负，早先为了「至少画一行」硬把 visible 抬到 1，
#     于是 5 行终端渲染出 6 行，把帧顶穿。
for amb in 1 2; do
  h_set_amb "${amb}"
  UI_COLS=1 UI_ROWS=24
  _home_layout
  t_begin "极窄 amb=${amb} cols=1"
  for sel in 0 5; do
    HOME_FOCUS="grid"
    HOME_SEL="${sel}"
    h_frame
    assert_eq "$(h_overflow 1)" "" "sel=${sel} 无行超出 1 列"
  done
done

h_set_amb 2
for rows in 1 5 6; do
  UI_COLS=24 UI_ROWS="${rows}"
  _home_layout
  t_begin "极矮 rows=${rows}"
  HOME_FOCUS="grid"
  HOME_SEL=5
  h_frame
  # 预算为负时钳到 0：能画 0 行已是极限，这里比的是「不超过」。
  want=$(( rows - 5 ))
  (( want < 0 )) && want=0
  assert_eq "$(( ${#_H_LINES[@]} <= want ))" "1" "帧高 <= max(0, UI_ROWS-5)"
done

# ---------------------------------------------------------------------------
# 3c. 选中卡片不得有背景色泄漏（本次回归）
# ---------------------------------------------------------------------------
# 真实存在过的 bug：home.sh 的图标卡（_home_card_a_rows）与迷你卡（_home_mini_card）
# 把带背景色的 UI_HL_FG（core_sgr <fg> <bg>，形如 48;5;N）当**纯前景色**用，于是选中卡
# 右侧 9 列文本区被刷成一块游离蓝底；而图标卡的描述行又写死 UI_MUTED，那块蓝中间还
# 破了个 9×5 的洞。修复：选中前景改用不含背景的 UI_SEL。
# 断言（本轮收窄口径）：整帧（含被选中的那张卡）里出现的**背景索引只准是本主题 UI_BG
# 的那一个**。旧口径「一个 48;5; 都不许有」的前提被本轮的整屏铺底打破了（UI_BG 合法地
# 铺满全帧），故改为「只准底色索引」——原 bug 的游离蓝底正是「一个不属于底色的索引」，
# 收窄后照样抓得住。
# 下面的用例覆盖图标卡（79 列下的档位 B）、迷你卡（40 列下的档位 C）与列表（档位 D）。
for amb in 1 2; do
  # 单独把图标钉在 half：理由见 h_bg_indices 注释（bg 图标自带合法的 48;5;）。
  BUPTY_AMBIG_W="${amb}"
  export BUPTY_FORCE_ICONS=half
  _ICON_INITIALIZED=""
  icon_init
  ui_box_init
  for spec in "79 24 B" "40 24 C" "24 24 D"; do
    read -r cols rows tier <<< "${spec}"
    UI_COLS="${cols}" UI_ROWS="${rows}"
    _home_layout
    t_begin "选中态无背景泄漏 档位${tier} amb=${amb} cols=${cols}"
    assert_eq "${_HOME_TIER}" "${tier}" "${cols} 列 × ${rows} 行应为档位 ${tier}"
    # 图例：本主题底色索引（dark=233）——非空且确为数字，否则下面的比对是空的。
    h_allow="$(h_ui_bg_index)"
    assert_eq "$(( h_allow > 0 ))" "1" "UI_BG 索引必须能反解出来（否则下一条恒真）"
    for sel in 0 1 5; do
      HOME_FOCUS="grid"
      HOME_SEL="${sel}"
      h_frame_raw
      assert_eq "$(h_bg_indices)" "${h_allow}" \
        "sel=${sel} 帧内背景索引只允许 UI_BG(${h_allow})，出现别的即泄漏"
    done
  done
done

# ---------------------------------------------------------------------------
# 4. 上下左右导航
# ---------------------------------------------------------------------------
t_begin "导航"
# 档位 A（3+3+1）：0..5 排成 2×3，卡 6 独占第三行第 1 列
UI_COLS=79 UI_ROWS=33
_home_layout
assert_eq "${_HOME_TIER}" "A" "79×33 → 档位 A"
HOME_FOCUS="grid" HOME_SEL=0
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "3" "A 档从 0 下移落到 3"
_home_move_vertical -1 && assert_eq "${HOME_SEL}" "0" "A 档从 3 上移回到 0"
assert_fail _home_move_vertical -1
assert_ok _home_move_vertical 1

# 3+3+1 的末行只有第 1 列：第 2 行的卡 4/5 按 ↓ 没有落点 → **保持原位**
# （旧行为是「吸附到最后一格」，会把无路可走的按键硬拽到卡 6 上）
HOME_SEL=4
assert_fail _home_move_vertical 1
assert_eq "${HOME_SEL}" "4" "3+3+1 卡 4 按下保持原位"
HOME_SEL=5
assert_fail _home_move_vertical 1
assert_eq "${HOME_SEL}" "5" "3+3+1 卡 5 按下保持原位"
HOME_SEL=3
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "6" "3+3+1 第 2 行第 1 列按下落到卡 6"

# 档位 B（同一个 3+3+1 栅格，只是行 2/行 3 换成迷你卡）：导航规则与 A 档一致
UI_COLS=79 UI_ROWS=24
_home_layout
assert_eq "${_HOME_TIER}" "B" "79×24 → 档位 B"
HOME_FOCUS="grid" HOME_SEL=5
assert_fail _home_move_vertical 1
assert_eq "${HOME_SEL}" "5" "B 档卡 5 按下保持原位"
HOME_SEL=3
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "6" "B 档卡 3 按下落到卡 6"

# 档位 C（2 列 × 4 行）：卡 5 是第 2 行第 2 列，末行只有卡 6
UI_COLS=40 UI_ROWS=24
_home_layout
assert_eq "${_HOME_TIER}" "C" "40×24 → 档位 C"
HOME_FOCUS="grid" HOME_SEL=5
assert_fail _home_move_vertical 1
assert_eq "${HOME_SEL}" "5" "C 档卡 5 按下保持原位（旧行为是吸附到卡 6）"
HOME_SEL=4
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "6" "C 档卡 4 按下落到卡 6"
HOME_SEL=5
_home_move_vertical -1 && assert_eq "${HOME_SEL}" "3" "C 档从 5 上移落到 3"

# 档位 D（1 列）：每行一张
UI_COLS=24 UI_ROWS=24
_home_layout
assert_eq "${_HOME_TIER}" "D" "24×24 → 档位 D"
HOME_FOCUS="grid" HOME_SEL=0
_home_move_vertical 1 && assert_eq "${HOME_SEL}" "1" "D 档逐行下移"

# 左右键不越列；设置焦点时左右键不动网格
UI_COLS=79 UI_ROWS=33
_home_layout
HOME_FOCUS="grid" HOME_SEL=0
handle_home_key LEFT
assert_eq "${HOME_SEL}" "0" "首列再按左不动"
HOME_SEL=2
handle_home_key RIGHT
assert_eq "${HOME_SEL}" "2" "第三列（行末）再按右不动"
HOME_SEL=1
handle_home_key LEFT
assert_eq "${HOME_SEL}" "0" "第二列按左回到第一列"

# ↑ 从第一行进入设置焦点；↓ 从设置焦点回到网格
HOME_FOCUS="grid" HOME_SEL=3
handle_home_key UP
assert_eq "${HOME_FOCUS}" "grid" "第二行按上仍在网格"
assert_eq "${HOME_SEL}" "0" "第二行按上落到第一行"
HOME_SEL=0
handle_home_key UP
assert_eq "${HOME_FOCUS}" "settings" "首行按上进入设置焦点"
handle_home_key DOWN
assert_eq "${HOME_FOCUS}" "grid" "设置焦点按下回到网格"
HOME_FOCUS="settings" HOME_SEL=0
handle_home_key LEFT
assert_eq "${HOME_SEL}" "0" "设置焦点时左键不动网格"

# ---------------------------------------------------------------------------
# 5. 装饰卡框（_home_decor_rows → _HOME_DECOR_BLOCK）
# ---------------------------------------------------------------------------
# 末行空位的占位框：与真卡同尺寸、同边框字形，整框 UI_MUTED，内部正中一个 …，
# **不可选中**（不参与 HOME_SEL / _home_pos，无 ▶/▸，也没有任何选中/悬停态）。
# 数量：档 A/B 末行 2 个（卡 6 右侧空出来的两格）、档 C 末行 1 个、档 D（列表）不画。
#
# 反向对照（本文件的传统，见第 0 节）：两个新量器必须「量得出东西」，否则下面那些
# 「= 2 / = 0」全是恒真。拿两条人工构造的帧行喂进去：数得清个数、也判得出标记。
_H_LINES=("│         …          │" "│         …   ▸      │")
h_count_char '…'
assert_eq "${_H_CNT}" "2" "反向对照：h_count_char 应数到 2 个 …"
h_decor_tail_mark
assert_eq "${_H_DECOR_TAIL_MARK}" "1" "反向对照：'…' 右边的 ▸ 必须被判成「装饰框内有标记」"

h_set_amb 1

t_begin "装饰框：单元（尺寸 / 字形 / 无标记）"
# 直接渲染装饰块本身：高 dch 行、每行宽 dcw 列、内部恰一个 …、绝无 ▶/▸。
for spec in "25 8" "25 3"; do
  read -r dcw dch <<< "${spec}"
  dhline=""
  for ((i = 0; i < dcw - 2; i++)); do dhline+="${_UI_BOX_H}"; done
  _home_decor_rows "${dcw}" "${dch}" "${dhline}"
  assert_eq "${#_HOME_DECOR_BLOCK[@]}" "${dch}" "装饰框高 ${dch} 行"
  dbad=""; docc=0
  for drow in "${_HOME_DECOR_BLOCK[@]}"; do
    drow="$(h_strip_ansi "${drow}")"
    assert_eq "$(h_width "${drow}")" "${dcw}" "装饰框每行宽 ${dcw} 列"
    case "${drow}" in *'▶'*|*'▸'*) dbad="有标记" ;; esac
    dtmp="${drow}"
    while [[ "${dtmp}" == *'…'* ]]; do docc=$((docc + 1)); dtmp="${dtmp#*…}"; done
  done
  assert_eq "${dbad}" "" "装饰框内不得出现 ▶/▸"
  assert_eq "${docc}" "1" "装饰框内恰有一个 … 当预留位"
done

t_begin "装饰框：数量与行数 / 行宽"
for spec in "79 33 A 26 2" "79 24 B 16 2" "40 24 C 15 1" "24 24 D 7 0"; do
  read -r cols rows tier want_lines want_decor <<< "${spec}"
  UI_COLS="${cols}"; UI_ROWS="${rows}"
  # 必须显式调一次：h_frame 的 render_home 跑在进程替换的子 shell 里，
  # 它在子 shell 内算出的 _HOME_TIER 传不回父 shell，父 shell 里只有这里算的值。
  _home_layout
  HOME_FOCUS="grid"; HOME_SEL=0
  h_frame
  assert_eq "${_HOME_TIER}" "${tier}" "cols=${cols} rows=${rows} → 档位 ${tier}"
  assert_eq "${#_H_LINES[@]}" "${want_lines}" "档位${tier} 帧行数恒为 ${want_lines}（装饰框不改变总行数）"
  h_count_char '…'
  assert_eq "${_H_CNT}" "${want_decor}" "档位${tier} 应有 ${want_decor} 个装饰框"
  h_decor_tail_mark
  assert_eq "${_H_DECOR_TAIL_MARK}" "0" "档位${tier} 装饰框内不得有选中标记"
  # 装饰框不改每行显示宽度：栅格档（A/B/C）各行等宽（D 是列表，宽度本就逐行不同）。
  if [[ "${tier}" != "D" ]]; then
    h_uniform
    assert_eq "${_H_BAD}" "" "档位${tier} 各行等宽（装饰框不撑宽/收窄任何一行）"
  fi
done

t_begin "装饰框：不随 HOME_SEL 变化（不可选中）"
for spec in "79 33 A" "79 24 B" "40 24 C"; do
  read -r cols rows tier <<< "${spec}"
  UI_COLS="${cols}"; UI_ROWS="${rows}"
  HOME_FOCUS="grid"
  dsig0=""
  for sel in 0 1 2 3 4 5 6; do
    HOME_SEL="${sel}"
    h_frame
    h_decor_sig
    (( sel == 0 )) && dsig0="${_H_DECOR_SIG}"
    assert_eq "${_H_DECOR_SIG}" "${dsig0}" "档位${tier} sel=${sel}：装饰行与 sel=0 逐字节一致"
  done
done

t_summary
