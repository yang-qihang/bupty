#!/usr/bin/env bash
# docs/palette-lab.sh —— 配色方案展示台（设计评审用；只读产品代码，不修改任何产品文件）。
#
# 这份脚本回答一个问题：bupty 的主题角色（11 个原有 + 新增 UI_SEL / UI_SEL_BORDER）
# 到底该取什么颜色。
#
#   * 候选方案全部来自公开发布、被广泛使用的 TUI 配色体系（出处见 LAB_SOURCES），
#     且**一律作为新增主题**提出：现有 dark / light / nord / gruvbox / high-contrast
#     一个都不改（dark 是用户已认可的默认观感，逐字节冻结）。
#   * 原色是 24 位真彩，本脚本把每个色**逐个映射到最近的 xterm-256 索引**——
#     欧氏距离、穷举 16..255（6×6×6 色立方 + 24 级灰阶），算法见 lab_nearest256；
#     映射不是凭感觉挑近似值，而是算出来的，且把「源色 / 索引 / 落点 / 偏差」全部打印。
#   * 展示的是**产品渲染路径本身**（lib/views/home.sh 的 _home_layout + _home_palette +
#     _home_render_cards），不是另画一套示意网格。所以形状、对齐、配色就是接进去之后的样子。
#   * 对比度按 WCAG 相对亮度公式现算（lab_contrast），低于 4.5 会明确标出来，不凭感觉。
#
# 选中态的约定（本轮定稿）：
#   **只靠结构性线索，绝不做背景填充。** 首页卡片的选中态 = ▶ 标记 + 方框换成
#   UI_SEL_BORDER（accent + bold，不含背景）+ 卡片正文换成 UI_SEL（纯前景，不含背景）。
#   换句话说：除了 UI_HL / UI_HL_FG 这两个「整行/整格铺满」的角色，任何角色都不得出现
#   48;5;（背景色）。文档 [a] 节的预览会临时把选中边框提到 UI_SEL_BORDER，以展示
#   「选中框比未选中的灰框明显拉开」的效果（产品文件一个字都不改）。
#
# 用法：
#   bash docs/palette-lab.sh                  # 依次看完所有方案（默认按 100 列渲染）
#   bash docs/palette-lab.sh mocha            # 只看一套
#   bash docs/palette-lab.sh all 80           # 全部方案，按 80 列渲染（看响应式退化）
#   bash docs/palette-lab.sh list             # 只列方案名（含「新增 / 同名冲突」标注）
#   bash docs/palette-lab.sh check            # 自检：SGR 合法性 / 索引范围 / 无背景色 / 帧宽 / 几何不变
#   BUPTY_FORCE_ICONS=bg bash docs/palette-lab.sh mocha    # 换图标档位预览
#
# 环境变量：BUPTY_FORCE_ICONS（half/bg/off，默认 half）、LAB_WIDTH（默认 100）。
# 宽度也可以直接作为第二个位置参数给出；Git Bash 下终端宽度探测不可靠，
# 本脚本**不猜**终端宽度，一律用参数或默认值。

set -uo pipefail

# 仓库根。刻意不 cd：被 tests/unit_palette.sh source 时不改变调用方的 cwd。
_LAB_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 只 source 产品代码，纯只读：core（SGR / 宽度引擎）、ui（角色变量 / 边框字符）、
# icons（图标三档）、views/home（首页渲染）。
# shellcheck disable=SC1091
source "${_LAB_HOME}/lib/core.sh"
# shellcheck disable=SC1091
source "${_LAB_HOME}/lib/ui.sh"
# shellcheck disable=SC1091
source "${_LAB_HOME}/lib/icons.sh"
# shellcheck disable=SC1091
source "${_LAB_HOME}/lib/views/home.sh"
# core.sh 自己带 set -e；本脚本按「逐项检查、计数、最后汇总」的方式跑，必须自己控制失败。
set +e

# 图标档位：默认 half（产品最常见的一档）。非 TTY 时 icon_init 内部仍会退 off，
# 但对本脚本来说无妨——几何与颜色才是展示重点。
: "${BUPTY_FORCE_ICONS:=half}"
export BUPTY_FORCE_ICONS
icon_init
ui_box_init   # 依赖 core.sh 的 BUPTY_AMBIG_W（加载时恒被初始化为 1 或 2）

# ===========================================================================
# 1. 颜色数学：hex ⇄ RGB、最近 256 色、WCAG 对比度
# ===========================================================================

# 全局状态先兜底初始化：本脚本跑在 set -u 下，任何「先读后写」都会直接打死进程。
LAB_R=0; LAB_G=0; LAB_B=0
LAB_IDX=-1; LAB_RGB="#000000"; LAB_D2=0
LAB_IDX_LIST=""; LAB_IDX_ONE=""; LAB_SGR=""; LAB_HEX_ONE=""
LAB_NAME=""; LAB_BG_CALC="#000000"; LAB_BG_IDX=-1; LAB_TIER="?"; LAB_PATCHED=""; LAB_USED=""
LAB_PLAIN=""; _LAB_ROLE_BAD=0
_LAB_LINES=(); _LAB_WIDTHS=()

# 十六进制 → 三个十进制分量，写全局 LAB_R / LAB_G / LAB_B。
# 只接受 #RRGGBB（6 位）。其它形状一律按 0 处理，绝不把非法值扔进算术（set -u 下会打死进程）。
lab_hex_rgb() {
  local h="${1:-}" body
  body="${h#\#}"
  if (( ${#body} != 6 )); then
    LAB_R=0; LAB_G=0; LAB_B=0
    return 1
  fi
  case "${body}" in
    *[!0-9a-fA-F]*) LAB_R=0; LAB_G=0; LAB_B=0; return 1 ;;
  esac
  LAB_R=$(( 16#${body:0:2} ))
  LAB_G=$(( 16#${body:2:2} ))
  LAB_B=$(( 16#${body:4:2} ))
  return 0
}

# xterm-256 索引 → #RRGGBB，写全局 LAB_RGB。
#   0-15   ：16 个系统色（每个终端自己定义，各家不同）——本脚本**不使用、不产出**；
#   16-231 ：6×6×6 色立方，分量取值 0 / 95 / 135 / 175 / 215 / 255；
#   232-255：24 级灰阶，取值 8 + 10*(i-232)。
# 刻意避开 0-15：那 16 个索引在不同终端里颜色不一样，写进主题就等于「颜色由用户终端决定」。
lab_256_hex() {
  local i="${1:-0}" t r g b
  if (( i >= 232 )); then
    r=$(( 8 + 10 * (i - 232) )); g="${r}"; b="${r}"
  else
    t=$(( i - 16 ))
    r=$(( t / 36 )); g=$(( (t % 36) / 6 )); b=$(( t % 6 ))
    (( r > 0 )) && r=$(( 55 + 40 * r ))
    (( g > 0 )) && g=$(( 55 + 40 * g ))
    (( b > 0 )) && b=$(( 55 + 40 * b ))
  fi
  printf -v LAB_RGB '#%02X%02X%02X' "${r}" "${g}" "${b}"
}

# 最近的 256 色索引（RGB 欧氏距离，穷举 16..255）。
# 写全局：LAB_IDX（索引）、LAB_RGB（落点 hex）、LAB_D2（距离的平方）。
# 距离平方是整数，比较用整数；打印时再开方（_lab_sqrt1）。
lab_nearest256() {
  local hex="${1:-}" r g b i t cr cg cb d
  lab_hex_rgb "${hex}"
  r="${LAB_R}"; g="${LAB_G}"; b="${LAB_B}"
  LAB_IDX=-1; LAB_D2=999999999
  LAB_RGB="#000000"
  for (( i = 16; i < 256; i++ )); do
    if (( i < 232 )); then
      t=$(( i - 16 ))
      cr=$(( t / 36 )); cg=$(( (t % 36) / 6 )); cb=$(( t % 6 ))
      (( cr > 0 )) && cr=$(( 55 + 40 * cr ))
      (( cg > 0 )) && cg=$(( 55 + 40 * cg ))
      (( cb > 0 )) && cb=$(( 55 + 40 * cb ))
    else
      cr=$(( 8 + 10 * (i - 232) )); cg="${cr}"; cb="${cr}"
    fi
    d=$(( (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb) ))
    if (( d < LAB_D2 )); then
      LAB_D2="${d}"
      LAB_IDX="${i}"
      printf -v LAB_RGB '#%02X%02X%02X' "${cr}" "${cg}" "${cb}"
    fi
  done
  return 0
}

# 距离平方 → 一位小数的距离（平方根交给 awk；本脚本只算十几次，不是热路径）。
_lab_sqrt1() {
  awk -v d="${1:-0}" 'BEGIN { printf "%.1f", sqrt(d) }'
}

# WCAG 2.x 相对亮度 + 对比度（浮点全交给 awk，bash 无浮点）。
# 公式：c' = c/255；c' <= 0.03928 ? c'/12.92 : ((c'+0.055)/1.055)^2.4
#       L = 0.2126R + 0.7152G + 0.0722B；对比度 = (L亮+0.05)/(L暗+0.05)
# 只用 POSIX awk 内建（手动 hex→dec，不用 gawk 的 strtonum，Git Bash 的 awk 也能跑）。
lab_contrast() {
  awk -v a="${1:-#000000}" -v b="${2:-#FFFFFF}" '
    function hx(s,   i, c, v) {
      v = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        v = v * 16 + (index("0123456789abcdef", c) - 1)
      }
      return v
    }
    function lin(c) { c /= 255; return (c <= 0.03928) ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
    function lum(h,   r, g, b) {
      r = lin(hx(substr(h, 2, 2))); g = lin(hx(substr(h, 4, 2))); b = lin(hx(substr(h, 6, 2)))
      return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    BEGIN {
      l1 = lum(a); l2 = lum(b)
      if (l1 < l2) { t = l1; l1 = l2; l2 = t }
      printf "%.2f", (l1 + 0.05) / (l2 + 0.05)
    }
  '
}

# 按显示列宽补齐（直接复用产品的 core_fit，中文表头才不会错位）。
lab_pad() { core_fit "${1:-}" "${2:-0}"; }

# ===========================================================================
# 2. 候选方案表
# ===========================================================================
#
# 方案清单。数组顺序 = `all` 的展示顺序 = 建议的设置页候选顺序。
# 全部为**新增**主题；dark / light / nord / gruvbox / high-contrast 一律不动。
# 其中 nord-frost、gruvbox-warm 与现有主题同源（见 LAB_NOTES 逐条说明）。
LAB_NAMES=(mocha tokyonight nord-frost gruvbox-warm kanagawa latte rosepine)
LAB_LABELS=(
  "Catppuccin Mocha"
  "Tokyo Night"
  "Nord（Frost 重映射）"
  "Gruvbox（暖色重映射）"
  "Kanagawa Wave"
  "Catppuccin Latte"
  "Rosé Pine Dawn"
)
LAB_SOURCES=(
  "Catppuccin（https://catppuccin.com）Mocha —— 2022 年后 TUI 社区事实标准的柔和暗色"
  "Tokyo Night（folke/tokyonight.nvim）Storm —— 冷蓝底 + 霓虹强调"
  "Nord（https://www.nordtheme.com）Polar Night / Frost / Aurora —— 冷峻克制的北欧色"
  "Gruvbox（morhetz/gruvbox）Dark medium —— 暖色复古，低饱和高辨识"
  "Kanagawa（rebelot/kanagawa.nvim）Wave —— 取自北斋《神奈川冲浪里》的日式墨色"
  "Catppuccin（https://catppuccin.com）Latte —— Mocha 的浅色对应（浅色方案）"
  "Rosé Pine Dawn（https://rosepinetheme.com）—— 奶油白底 + 灰紫墨（浅色方案）"
)
# dark = 深色终端；light = 浅色终端（配白底终端使用）。
LAB_VARIANTS=(dark dark dark dark dark light light)
# 每套方案在「主题清单」里的处置建议（新增 / 同名冲突）。
LAB_NOTES=(
  "新增主题：mocha 与现有任何主题都不重名，可直接加进 UI_THEME_NAMES"
  "新增主题：tokyonight 与现有任何主题都不重名，可直接加进 UI_THEME_NAMES"
  "新增主题（与现有 nord 同源）：色相相同但 256 映射是重算的——现有 nord 的 accent 取 110(#87D7D7)，#88C0D0 的真正最近邻是 104(#87AFFF)。二选一：改名新增为 nord-frost，或直接替换现有 nord 条目（推荐后者，避免两套近重复主题）"
  "新增主题（与现有 gruvbox 同源）：同上，现有 gruvbox 的 accent 取 109(#87D7AF)，#83A598 的真正最近邻是 101(#87AF87)"
  "新增主题：kanagawa 与现有任何主题都不重名，可直接加进 UI_THEME_NAMES"
  "新增主题 × 浅色：latte 是第 2 套浅色主题（现有 light 仍在，不动）"
  "新增主题 × 浅色：rosepine 是第 3 套浅色主题"
)

# 候选方案的基准底色（产品 UI_BG 的唯一权威来源）。
#
# **结构上不再有两个需要人手动对齐的平行数组**：方案名与底色成对写在关联数组
# LAB_BG_OF 里，LAB_BG_BASE 由 LAB_NAMES 逐个派生而来 —— 两者长度**必然相等**，
# 靠的是下面这个循环本身，而不是「记得同步两个数组」。这正是本轮修掉的坑：
# 旧写法里 LAB_BG_BASE 被追加过 3 个既有主题、成了 10 项，与 7 项的 LAB_NAMES 脱钩，
# 而所有消费点都按 LAB_NAMES 的下标取，多出来的 3 项永远读不到、也没人发现。
#   深色方案取自己的 base；浅色方案取纯白 #FFFFFF（深字的最坏情况）。
#   漏写一个映射 → 派生值是空串；写坏一个 → 派生值不是 #RRGGBB。两种情况
#   tests/unit_palette.sh 都会红（它按「合法 hex 个数 == 方案数」判）。
#   产品每套主题的 UI_BG 索引必须 == lab_nearest256(此表对应 hex)，逐字节一致（沿用配色护栏口径）。
# 注意：数组字面量里 `#` 在空白之后会被当成注释开头，所以每项都要加引号。
declare -A LAB_BG_OF=(
  [mocha]="#1E1E2E"          # base
  [tokyonight]="#24283B"     # bg（storm）
  [nord-frost]="#2E3440"     # nord0（与产品 nord 同源）
  [gruvbox-warm]="#282828"   # bg0（与产品 gruvbox 同源）
  [kanagawa]="#1C1C1C"       # sumiInk1 #1F1F28 的 256 落点 #262626 会让 muted 掉到 2.88，改取更深的近黑
  [latte]="#FFFFFF"          # 纯白
  [rosepine]="#FFFFFF"       # 纯白
)
LAB_BG_BASE=()
for _lab_bg_name in "${LAB_NAMES[@]}"; do
  LAB_BG_BASE+=("${LAB_BG_OF[${_lab_bg_name}]:-}")
done
unset _lab_bg_name

# 产品**既有**主题的底色（dark / light / high-contrast）——产品 UI_BG 的另一半来源。
#   独立命名、独立取值：与候选方案表彻底分开，既不参与 LAB_NAMES 的下标对应，
#   也不会再被塞进 LAB_BG_BASE 去和它比长度（那正是旧写法的病根）。
#   用关联数组按主题名取，不依赖任何下标顺序；值一个都没动。
declare -A LAB_BG_EXISTING=(
  [dark]="#101010"           # 极深近黑（原观感是终端黑，别偏离太远）
  [light]="#FFFFFF"          # 纯白
  [high-contrast]="#000000"  # 纯黑（白字最大化对比）
)

# 角色源色（24 位）。每一行都注明取自该体系里的哪个具名色。
# 变量命名 LAB_<角色>；hl_fg / hl_bg 是「反显药丸」的前景与背景两色。
LAB_ACCENT=""; LAB_TEXT=""; LAB_MUTED=""; LAB_BORDER=""
LAB_SUCCESS=""; LAB_WARNING=""; LAB_DANGER=""; LAB_PURPLE=""
LAB_TITLE=""; LAB_SEL=""; LAB_SELBORDER=""; LAB_HLFG=""; LAB_HLBG=""; LAB_BASE=""

# --- Catppuccin Mocha -------------------------------------------------------
_lab_roles_mocha() {
  LAB_ACCENT="#89B4FA"      # blue
  LAB_TEXT="#CDD6F4"        # text
  LAB_MUTED="#9399B2"       # overlay2（比 subtext0 暗一档，才像「次要文字」）
  LAB_BORDER="#45475A"      # surface1（未选中卡片方框）
  LAB_SUCCESS="#A6E3A1"     # green
  LAB_WARNING="#F9E2AF"     # yellow
  LAB_DANGER="#F38BA8"      # red
  LAB_PURPLE="#CBA6F7"      # mauve
  LAB_TITLE="#89B4FA"       # blue
  LAB_SEL="#B4BEFE"         # lavender（选中卡片正文，纯前景）
  LAB_SELBORDER="#89B4FA"   # blue + bold（选中卡片方框）
  LAB_HLFG="#11111B"        # crust（药丸文字）
  LAB_HLBG="#89B4FA"        # blue（药丸底）
  LAB_BASE="#1E1E2E"        # base
}

# --- Tokyo Night（Storm） ---------------------------------------------------
_lab_roles_tokyonight() {
  LAB_ACCENT="#7AA2F7"      # blue
  LAB_TEXT="#C0CAF5"        # fg
  LAB_MUTED="#A9B1D6"       # fg_dark
  LAB_BORDER="#414868"      # terminal_black
  LAB_SUCCESS="#9ECE6A"     # green
  LAB_WARNING="#E0AF68"     # yellow
  LAB_DANGER="#F7768E"      # red
  LAB_PURPLE="#BB9AF7"      # magenta
  LAB_TITLE="#7AA2F7"       # blue
  LAB_SEL="#7DCFFF"         # cyan
  LAB_SELBORDER="#7AA2F7"   # blue + bold
  LAB_HLFG="#1A1B26"        # bg_dark
  LAB_HLBG="#7AA2F7"        # blue
  LAB_BASE="#24283B"        # bg（storm）
}

# --- Nord -------------------------------------------------------------------
_lab_roles_nord_frost() {
  LAB_ACCENT="#88C0D0"      # nord8 Frost
  LAB_TEXT="#D8DEE9"        # nord4 Snow Storm
  # Nord 官方没有「次要文字灰」。曾试过官方色表里最接近中性的 nord9（#81A1C1），
  # 但它与选中正文用的 nord7（#8FBCBB）**在 256 色里落到同一个索引 109**——
  # 于是首页选中卡片的「名称」（UI_SEL）和「描述」（UI_MUTED）会变成同一种颜色，
  # 这比「缺官方灰」严重得多。因此改回中性灰：灰阶 158（#9E9E9E，深底对比度 4.66），
  # 与现有 nord 主题的取法一致（那边也是自造灰）。
  LAB_MUTED="#9E9E9E"       # 中性灰（灰阶 158；Nord 无官方灰，与现有 nord 同源）
  LAB_BORDER="#4C566A"      # nord3 Polar Night
  LAB_SUCCESS="#A3BE8C"     # nord14 Aurora green
  LAB_WARNING="#EBCB8B"     # nord13 Aurora yellow
  LAB_DANGER="#BF616A"      # nord11 Aurora red
  LAB_PURPLE="#B48EAD"      # nord15 Aurora purple
  LAB_TITLE="#88C0D0"       # nord8
  LAB_SEL="#8FBCBB"         # nord7 Frost
  LAB_SELBORDER="#88C0D0"   # nord8 + bold
  LAB_HLFG="#2E3440"        # nord0
  LAB_HLBG="#88C0D0"        # nord8
  LAB_BASE="#2E3440"        # nord0
}

# --- Gruvbox Dark -----------------------------------------------------------
_lab_roles_gruvbox_warm() {
  LAB_ACCENT="#83A598"      # blue
  LAB_TEXT="#EBDBB2"        # fg
  LAB_MUTED="#A89984"       # fg4 / gray
  LAB_BORDER="#504945"      # bg2
  LAB_SUCCESS="#B8BB26"     # green
  LAB_WARNING="#FABD2F"     # yellow
  LAB_DANGER="#FB4934"      # red
  LAB_PURPLE="#D3869B"      # purple
  LAB_TITLE="#83A598"       # blue
  LAB_SEL="#FABD2F"         # yellow
  LAB_SELBORDER="#83A598"   # blue + bold
  LAB_HLFG="#282828"        # bg0
  LAB_HLBG="#83A598"        # blue
  LAB_BASE="#282828"        # bg0
}

# --- Kanagawa Wave ----------------------------------------------------------
_lab_roles_kanagawa() {
  LAB_ACCENT="#7E9CD8"      # crystalBlue
  LAB_TEXT="#DCD7BA"        # fujiWhite
  LAB_MUTED="#727169"       # fujiGray（官方注释色；对比度见报告，偏低）
  LAB_BORDER="#54546D"      # sumiInk4
  LAB_SUCCESS="#98BB6C"     # springGreen
  LAB_WARNING="#E6C384"     # carpYellow
  LAB_DANGER="#E46876"      # waveRed
  LAB_PURPLE="#957FB8"      # oniViolet
  LAB_TITLE="#7E9CD8"       # crystalBlue
  LAB_SEL="#7FB4CA"         # springBlue
  LAB_SELBORDER="#7E9CD8"   # crystalBlue + bold
  LAB_HLFG="#1F1F28"        # sumiInk1
  LAB_HLBG="#7E9CD8"        # crystalBlue
  LAB_BASE="#1F1F28"        # sumiInk1
}

# --- Catppuccin Latte（浅色） -----------------------------------------------
_lab_roles_latte() {
  LAB_ACCENT="#1E66F5"      # blue
  LAB_TEXT="#4C4F69"        # text
  LAB_MUTED="#6C6F85"       # subtext0
  LAB_BORDER="#9CA0B0"      # overlay0
  LAB_SUCCESS="#40A02B"     # green
  LAB_WARNING="#DF8E1D"     # yellow
  LAB_DANGER="#D20F39"      # red
  LAB_PURPLE="#8839EF"      # mauve
  LAB_TITLE="#1E66F5"       # blue
  # 选中正文。**不能用 mauve**：mauve #8839EF 的 256 落点是 #875FFF，白底上只有 4.11
  # （源真彩算出来是 5.41，那是「本该有的」而不是屏幕上真的），AA 不过。
  # Catppuccin Latte 里白底 ≥4.5 的非文字色只剩 blue 与 red，red 是「危险」语义，
  # 所以选中正文复用 blue（落点 #005FFF，4.91）——与选中方框同色，只差加粗。
  LAB_SEL="#1E66F5"         # blue
  LAB_SELBORDER="#1E66F5"   # blue + bold
  LAB_HLFG="#FFFFFF"        # 白字
  LAB_HLBG="#1E66F5"        # blue 底
  LAB_BASE="#EFF1F5"        # base
}

# --- Rosé Pine Dawn（浅色） -------------------------------------------------
_lab_roles_rosepine() {
  LAB_ACCENT="#286983"      # pine
  LAB_TEXT="#575279"        # text
  LAB_MUTED="#797593"       # subtle（对比度 < 4.5，见报告）
  LAB_BORDER="#CECACD"      # highlightHigh（白底上偏淡，见报告）
  LAB_SUCCESS="#56949F"     # foam（Rosé Pine 没有绿，用青绿代替「成功」）
  LAB_WARNING="#EA9D34"     # gold
  LAB_DANGER="#B4637A"      # love
  LAB_PURPLE="#907AA9"      # iris
  LAB_TITLE="#286983"       # pine
  # 选中正文。Rosé Pine **Dawn 这一档里没有 ≥4.5 的紫/鸢尾色**（iris #907AA9 在白底上
  # 只有 3.79，AA 不过），所以选中正文改用 pine（6.11）——与选中方框同色相，
  # 「这张卡被选中了」整体读作同一个色。它与 UI_SEL_BORDER 只差加粗。
  LAB_SEL="#286983"         # pine
  LAB_SELBORDER="#286983"   # pine + bold
  LAB_HLFG="#FAF4ED"        # base（药丸文字）
  LAB_HLBG="#286983"        # pine 底
  LAB_BASE="#FAF4ED"        # base
}

# 方案名是否在清单内。
lab_has_palette() {
  local n="${1:-}" x
  for x in "${LAB_NAMES[@]}"; do
    [[ "${x}" == "${n}" ]] && return 0
  done
  return 1
}

# 方案下标（0 基）。**未知方案不打印任何东西、返回 1**——刻意不再返回 -1。
#   为什么：bash 里 `arr[-1]` 取的是**最后一个元素**，不报错。旧实现返回 -1，
#   任何绕过 lab_load_roles 失败检查、直接 `LAB_BG_BASE[-1]` 的写法都会**静默**拿到
#   表尾那个元素（旧表尾恰好是 high-contrast 的 #000000，即纯黑）。改成「无输出 + 非 0」
#   之后，想按下标取值必须先处理失败分支，否则拿到的是空串（一目了然），不会撞到别的元素。
# 调用点（本轮已逐一确认）：lab_bg_base（下方）、lab_show。全仓库再无其它调用者。
lab_index() {
  local n="${1:-}" i
  [[ -n "${n}" ]] || return 1
  for i in "${!LAB_NAMES[@]}"; do
    if [[ "${LAB_NAMES[$i]}" == "${n}" ]]; then printf '%s' "${i}"; return 0; fi
  done
  return 1
}

# 取某候选方案的基准底色 → 全局 LAB_BG_CALC。
#   未知方案：不改 LAB_BG_CALC，返回 1（绝不按下标去撞别的元素）。
#   这不是「只靠调用方自觉」：下标范围在这里再兜一道，即便 lab_index 将来被改坏
#   （又返回 -1、或返回越界值），也取不到表里的任何元素。
lab_bg_base() {
  local n="${1:-}" idx
  idx="$(lab_index "${n}")" || return 1
  (( idx >= 0 && idx < ${#LAB_BG_BASE[@]} )) || return 1
  LAB_BG_CALC="${LAB_BG_BASE[$idx]}"
  return 0
}

# ===========================================================================
# 3. 把方案落到产品的 UI_* 角色变量上
# ===========================================================================
#
# 角色分工（本轮定稿，实现时请照抄这段注释到 lib/ui.sh）：
#   UI_BORDER      未选中卡片的方框色。低对比、只负责「描出格子」，不抢内容。
#   UI_SEL_BORDER  选中卡片的方框色。**结构性线索**：accent + bold、不含背景。
#                  它与 UI_BORDER 的差别就是「一眼看出选中」的全部依据。
#   UI_SEL         选中卡片的正文色。纯前景、不含背景（曾用 UI_HL_FG 顶替，
#                  那会带出 48;5; 背景块，就是首页 9 列色块那个 bug 的根因）。
#   UI_HL / UI_HL_FG  仅有的两个**允许带背景**的角色：整行/整格铺满的场景
#                  （列表选中行、设置项、反显药丸）。页面里不得拿它们当纯前景色用。

# 报告/样张里 UI_* 角色的统一顺序。
LAB_UI_ROLES=(title text muted border accent success warning danger purple sel sel_border hl hl_fg)
# 角色 → 报告里展示的变量名。
LAB_ROLE_VARS=(
  UI_TITLE UI_TEXT UI_MUTED UI_BORDER UI_ACCENT UI_SUCCESS UI_WARNING
  UI_DANGER UI_PURPLE UI_SEL UI_SEL_BORDER UI_HL UI_HL_FG
)
# 「铺满型」角色：唯一允许出现背景色（48;5;）的两个。
LAB_FILL_ROLES=(hl hl_fg)
# 只有这两个角色允许带背景色。

# 载入方案源色。未知方案返回 1（不改变当前值）。
lab_load_roles() {
  case "${1:-}" in
    mocha) _lab_roles_mocha ;;
    tokyonight) _lab_roles_tokyonight ;;
    nord-frost) _lab_roles_nord_frost ;;
    gruvbox-warm) _lab_roles_gruvbox_warm ;;
    kanagawa) _lab_roles_kanagawa ;;
    latte) _lab_roles_latte ;;
    rosepine) _lab_roles_rosepine ;;
    *) return 1 ;;
  esac
  return 0
}

# 某角色的源色 hex → 全局 LAB_HEX_ONE。
lab_role_hex() {
  case "${1:-}" in
    title) LAB_HEX_ONE="${LAB_TITLE}" ;;
    text) LAB_HEX_ONE="${LAB_TEXT}" ;;
    muted) LAB_HEX_ONE="${LAB_MUTED}" ;;
    border) LAB_HEX_ONE="${LAB_BORDER}" ;;
    accent) LAB_HEX_ONE="${LAB_ACCENT}" ;;
    success) LAB_HEX_ONE="${LAB_SUCCESS}" ;;
    warning) LAB_HEX_ONE="${LAB_WARNING}" ;;
    danger) LAB_HEX_ONE="${LAB_DANGER}" ;;
    purple) LAB_HEX_ONE="${LAB_PURPLE}" ;;
    sel) LAB_HEX_ONE="${LAB_SEL}" ;;
    sel_border) LAB_HEX_ONE="${LAB_SELBORDER}" ;;
    hl_fg) LAB_HEX_ONE="${LAB_HLFG}" ;;
    hl_bg) LAB_HEX_ONE="${LAB_HLBG}" ;;
    *) LAB_HEX_ONE="" ;;
  esac
}

# 角色 → 当前 SGR 串，写全局 LAB_SGR（零 fork：检查循环里被反复调用）。
lab_role_sgr() {
  case "${1:-}" in
    accent) LAB_SGR="${UI_ACCENT}" ;;
    text) LAB_SGR="${UI_TEXT}" ;;
    muted) LAB_SGR="${UI_MUTED}" ;;
    border) LAB_SGR="${UI_BORDER}" ;;
    hl) LAB_SGR="${UI_HL}" ;;
    hl_fg) LAB_SGR="${UI_HL_FG}" ;;
    success) LAB_SGR="${UI_SUCCESS}" ;;
    warning) LAB_SGR="${UI_WARNING}" ;;
    danger) LAB_SGR="${UI_DANGER}" ;;
    purple) LAB_SGR="${UI_PURPLE}" ;;
    title) LAB_SGR="${UI_TITLE}" ;;
    sel) LAB_SGR="${UI_SEL}" ;;
    sel_border) LAB_SGR="${UI_SEL_BORDER}" ;;
    *) LAB_SGR="" ;;
  esac
  return 0
}

# 应用一套方案到 UI_* 角色变量（全部经由产品的 core_sgr 构造，不硬编码 ANSI）。
lab_apply() {
  local name="${1:-}"
  lab_load_roles "${name}" || return 1
  lab_bg_base "${name}" || return 1        # 未知方案绝不会落到 LAB_BG_BASE[-1]
  LAB_NAME="${name}"

  lab_nearest256 "${LAB_BG_CALC}";   LAB_BG_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_ACCENT}";    LAB_ACCENT_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_TEXT}";      LAB_TEXT_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_MUTED}";     LAB_MUTED_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_BORDER}";    LAB_BORDER_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_SUCCESS}";   LAB_SUCCESS_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_WARNING}";   LAB_WARNING_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_DANGER}";    LAB_DANGER_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_PURPLE}";    LAB_PURPLE_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_TITLE}";     LAB_TITLE_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_SEL}";       LAB_SEL_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_SELBORDER}"; LAB_SELBORDER_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_HLFG}";      LAB_HLFG_IDX="${LAB_IDX}"
  lab_nearest256 "${LAB_HLBG}";      LAB_HLBG_IDX="${LAB_IDX}"

  UI_ACCENT="$(core_sgr "${LAB_ACCENT_IDX}")"
  UI_TEXT="$(core_sgr "${LAB_TEXT_IDX}")"
  UI_MUTED="$(core_sgr "${LAB_MUTED_IDX}")"
  UI_BORDER="$(core_sgr "${LAB_BORDER_IDX}")"
  UI_SUCCESS="$(core_sgr "${LAB_SUCCESS_IDX}")"
  UI_WARNING="$(core_sgr "${LAB_WARNING_IDX}")"
  UI_DANGER="$(core_sgr "${LAB_DANGER_IDX}")"
  UI_PURPLE="$(core_sgr "${LAB_PURPLE_IDX}")"
  UI_TITLE="$(core_sgr "${LAB_TITLE_IDX}" bold)"
  # 选中态正文：**不含背景**。选中态的背景填充正是首页 9 列色块那个已知 bug 的根源，
  # 所以这个角色只给前景，背景交给终端。
  UI_SEL="$(core_sgr "${LAB_SEL_IDX}" bold)"
  # 选中态方框：accent + bold、**不含背景**。与 UI_BORDER（灰、不加粗）拉开差距，
  # 这就是「一眼看出选中」的全部依据。
  UI_SEL_BORDER="$(core_sgr "${LAB_SELBORDER_IDX}" bold)"
  # 反显药丸（列表选中行 / 设置项）：允许带背景——它按定义就要铺满一整行。
  UI_HL="$(core_sgr "${LAB_HLFG_IDX}" "${LAB_HLBG_IDX}" bold)"
  UI_HL_FG="$(core_sgr "${LAB_HLFG_IDX}" "${LAB_HLBG_IDX}" bold)"
  UI_BG="$(core_sgr "" "${LAB_BG_IDX}")"
  UI_RESET="$(core_c_reset)${UI_BG}"
  return 0
}

# ===========================================================================
# 4. 首页卡片网格（直接调产品渲染路径）
# ===========================================================================

# 渲染首页一帧。
#   lab_render_home <宽度>
# 结果：整帧写 stdout；档位写 LAB_TIER；打过的垫片写 LAB_PATCHED（可读的说明串）。
#
# 兼容垫片：产品文件一行都不改，只在渲染**期间**临时替换两个变量，让预览展示
# 「按本轮约定修好之后」的观感：
#   1) 选中方框：产品现在用 UI_ACCENT（普通强调色，不加粗）画选中卡片的方框。
#      新约定是 UI_SEL_BORDER（accent + bold）——预览期间把 UI_ACCENT 换成它，
#      方框立刻比未选中的灰框醒目一档。工作树里一旦改用 UI_SEL_BORDER，垫片自动失效。
#   2) 选中正文：更早的工作树用 UI_HL_FG 当纯前景色（带 48;5; 背景 → 名称行 9 列
#      背景块，即那个已知 bug）。若检测到这种写法，临时换成 UI_SEL。
lab_render_home() {
  local w="${1:-100}"
  UI_COLS="${w}"
  UI_ROWS=30
  HOME_FOCUS="grid"
  HOME_SEL=1        # 选中中间那张卡片（课表），一屏里能同时看到选中态与未选中态

  LAB_PATCHED=""
  if ! declare -F _home_layout >/dev/null 2>&1 || ! declare -F _home_render_cards >/dev/null 2>&1; then
    # 产品接口变了：退回最外层的 render_home，至少不崩。
    if declare -F render_home >/dev/null 2>&1; then
      render_home || true
      _home_layout || true
      LAB_TIER="${_HOME_TIER:-?}"
    else
      printf '（无法渲染：lib/views/home.sh 未提供预期的渲染函数）\n'
      LAB_TIER="?"
    fi
    return 0
  fi

  local fdef saved_acc="" saved_hl=""
  fdef="$(declare -f _home_card_a_rows _home_mini_card 2>/dev/null)"
  if [[ "${fdef}" != *UI_SEL_BORDER* ]]; then
    saved_acc="${UI_ACCENT}"
    UI_ACCENT="${UI_SEL_BORDER}"
    LAB_PATCHED+="选中方框：UI_ACCENT → UI_SEL_BORDER（accent + bold，无背景）；"
  fi
  if [[ "${fdef}" != *UI_SEL* ]]; then
    saved_hl="${UI_HL_FG}"
    UI_HL_FG="${UI_SEL}"
    LAB_PATCHED+="选中正文：UI_HL_FG → UI_SEL（去掉背景块）；"
  fi

  _home_layout
  _home_palette
  case "${_HOME_TIER}" in
    A) _home_render_cards ;;
    B) _home_render_mini ;;
    *) _home_render_list ;;
  esac || true
  LAB_TIER="${_HOME_TIER}"
  [[ -n "${saved_acc}" ]] && UI_ACCENT="${saved_acc}"
  [[ -n "${saved_hl}" ]] && UI_HL_FG="${saved_hl}"
  return 0
}

# ===========================================================================
# 5. 展示：分节打印
# ===========================================================================

# 一行横线。
_lab_rule() {
  local n="${1:-60}" i
  for (( i = 0; i < n; i++ )); do printf '%s' '─'; done
  printf '\n'
}

# 小节标题。
_lab_head() {
  printf '\n%s%s%s\n' "$(core_c_bold)" "$1" "${UI_RESET}"
}

# (a) 真实首页卡片网格。
_lab_show_home() {
  local w="$1" tier
  # 先只算档位（_home_layout 是纯计算），好在标题里报出来；渲染仍在父 shell 里做，
  # 这样 lab_render_home 写的 LAB_TIER / LAB_PATCHED 不会被命令替换的子 shell 吃掉。
  UI_COLS="${w}"; UI_ROWS=30
  _home_layout || true
  tier="${_HOME_TIER:-?}"
  _lab_head "[a] 首页卡片网格 —— 直接调 lib/views/home.sh（UI_COLS=${w}，档位 ${tier}）"
  lab_render_home "${w}"
  if [[ -n "${LAB_PATCHED}" ]]; then
    printf '%s预览垫片（产品文件未改动）：%s%s\n' "${UI_MUTED}" "${LAB_PATCHED}" "${UI_RESET}"
  fi
}

# (b) 角色样张：每个角色都用**实际文字**渲染，一眼看出配色关系。
_lab_show_roles() {
  local i role var line
  local -a sample=(
    "bupty · 北京邮电大学校园信息查询"
    "2025-2026 学年第一学期 · 第 6 周 · 北京时间 14:05"
    "数据缓存于 3 分钟前，按 r 刷新"
    "┌─────────────┐  未选中卡片的方框"
    "按 Enter 进入「作业 DDL」"
    "● 已同步 6 个模块"
    "▲ 有 2 门考试在 7 天内开始"
    "■ 教学云登录失败：密码已过期"
    "● 公共查询：空教室 / 班车 / 校历"
    "作业 DDL（选中卡片正文·纯前景·无背景）"
    "┌─────────────┐  选中卡片的方框（accent+bold）"
    "反显药丸：选中整行 / 设置项（唯一允许铺底的场景）"
    "同上一行：UI_HL / UI_HL_FG 是同一个药丸的两半"
  )
  _lab_head "[b] 角色样张"
  for i in "${!LAB_UI_ROLES[@]}"; do
    role="${LAB_UI_ROLES[$i]}"
    var="${LAB_ROLE_VARS[$i]}"
    lab_role_sgr "${role}"
    printf '  %s%s%s  %s%s%s\n' \
      "${UI_MUTED}" "$(lab_pad "${var}" 15)" "${UI_RESET}" "${LAB_SGR}" "${sample[$i]}" "${UI_RESET}"
  done
}

# (c) 256 色映射对照表：源色 / 索引 / 落点 / 偏差 / 样本。
_lab_show_map() {
  local i role var hex idx rgb d2 d
  local -a mroles=(title text muted border accent success warning danger purple sel sel_border hl_fg hl_bg)
  _lab_head "[c] 256 色映射对照（源真彩 → 最近 256 索引）"
  printf '  %s%s%s\n' "${UI_MUTED}" \
    "$(lab_pad '角色' 16)$(lab_pad '源色(24位)' 14)$(lab_pad '256' 6)$(lab_pad '落点RGB' 11)$(lab_pad 'ΔRGB' 7)样本：原色 / 256色" \
    "${UI_RESET}"

  LAB_USED=""
  for role in "${mroles[@]}"; do
    case "${role}" in
      hl_bg) var="UI_HL(背景)" ;;
      *)     var="UI_$(printf '%s' "${role}" | tr 'a-z' 'A-Z')" ;;
    esac
    lab_role_hex "${role}"
    hex="${LAB_HEX_ONE}"
    lab_nearest256 "${hex}"
    idx="${LAB_IDX}"; rgb="${LAB_RGB}"; d2="${LAB_D2}"
    d="$(_lab_sqrt1 "${d2}")"
    [[ " ${LAB_USED} " == *" ${idx} "* ]] || LAB_USED+="${idx} "
    printf '  %s%s%s%s%s%s██████%s%s██████%s\n' \
      "$(lab_pad "${var}" 16)" "$(lab_pad "${hex}" 14)" "$(lab_pad "${idx}" 6)" \
      "$(lab_pad "${rgb}" 11)" "$(lab_pad "${d}" 7)" \
      "$(lab_sgr_true "${hex}")" "${UI_RESET}" "$(core_sgr '' "${idx}")" "${UI_RESET}"
  done

  # 去重后的索引清单（升序），每个索引打印它真正的 RGB。
  _lab_head "[c2] 本方案用到的全部 256 索引（升序，附色块）"
  local idxs
  idxs="$(printf '%s\n' ${LAB_USED} | sort -n | tr '\n' ' ')"
  printf '  %s%s%s\n' "${UI_MUTED}" "$(lab_pad '索引' 6)$(lab_pad '实际RGB' 11)色块" "${UI_RESET}"
  for idx in ${idxs}; do
    lab_256_hex "${idx}"
    printf '  %s%s%s%s\n' \
      "$(lab_pad "${idx}" 6)" "$(lab_pad "${LAB_RGB}" 11)" "$(core_sgr '' "${idx}")      " "${UI_RESET}"
  done
  printf '%s  说明：色块是终端真正会画出来的颜色（6 个空格）。ΔRGB 是「源真彩 → 256 落点」的\n' "${UI_MUTED}"
  printf '       欧氏距离：≤5 基本看不出差别，>12 说明这个色在 256 色里没有好替代（色立方步长 40）。%s\n' "${UI_RESET}"
}

# 真彩色样本 SGR（仅用于「原色 vs 256 落点」对照——产品只支持 256 色，
# 这里打印 48;2;r;g;b 不是为了用，而是为了让人**看见** 256 色丢了多少）。
lab_sgr_true() {
  local hex="${1:-#000000}"
  lab_hex_rgb "${hex}"
  printf '\033[48;2;%d;%d;%dm' "${LAB_R}" "${LAB_G}" "${LAB_B}"
}

# (d) 对比度（WCAG）。
#
# **按 256 落点色算，不按上游真彩色算**：产品只发 38;5;N，屏幕上真正显示的颜色是
# 「索引对应的 RGB」。上游真彩与 256 落点的 ΔRGB 可达 40（浅色方案里尤其明显），
# 拿真彩色算出来的对比度是「本该有的对比度」，不是用户**实际看到**的对比度。
# 源色仍然列出来，只作参照。
_lab_show_contrast() {
  local bg="${LAB_BG_CALC}"
  _lab_head "[d] 对比度（WCAG 相对亮度，按 256 落点色计算，基准背景 ${bg}）"
  printf '%s  %s  %s  %s  %s%s\n' "${UI_MUTED}" \
    "$(lab_pad '角色' 10)" "$(lab_pad '变量' 15)" "$(lab_pad '源色→256落点' 20)" \
    "$(lab_pad '比值' 6)" '判定' "${UI_RESET}"
  local pairs=(text:正文 muted:次要 title:标题 sel:选中正文 sel_border:选中方框 accent:强调 danger:危险 success:成功 warning:警告 purple:紫色 border:未选中方框)
  local p role cn hex land ratio verdict
  for p in "${pairs[@]}"; do
    role="${p%%:*}"
    cn="${p#*:}"
    lab_role_hex "${role}"
    hex="${LAB_HEX_ONE}"
    lab_nearest256 "${hex}"
    land="${LAB_RGB}"
    ratio="$(lab_contrast "${land}" "${bg}")"
    verdict="$(awk -v r="${ratio}" 'BEGIN { if (r >= 4.5) print "AA 正文"; else if (r >= 3.0) print "大字号/图标"; else print "偏低" }')"
    printf '  %s%s%s  %s  %s  %s%s%s  %s\n' \
      "${UI_MUTED}" "$(lab_pad "${cn}" 10)" "${UI_RESET}" "$(lab_pad "UI_$(printf '%s' "${role}" | tr 'a-z' 'A-Z')" 15)" \
      "$(lab_pad "${hex}→${land}" 20)" \
      "$(awk -v r="${ratio}" 'BEGIN { print (r >= 4.5 ? "" : "\033[33m") }')" \
      "$(lab_pad "${ratio}" 6)" "${UI_RESET}" "${verdict}"
  done
  # 反显药丸（UI_HL / UI_HL_FG）是唯一铺底的场景，它的可读性取决于「药丸前景 vs 药丸底色」，
  # 而不是 vs 页面背景——单独算一行，别拿页面背景糊弄过去。
  local hl_fg_land hl_bg_land hl_ratio hl_verdict
  lab_nearest256 "${LAB_HLFG}"; hl_fg_land="${LAB_RGB}"
  lab_nearest256 "${LAB_HLBG}"; hl_bg_land="${LAB_RGB}"
  hl_ratio="$(lab_contrast "${hl_fg_land}" "${hl_bg_land}")"
  hl_verdict="$(awk -v r="${hl_ratio}" 'BEGIN { if (r >= 4.5) print "AA 正文"; else if (r >= 3.0) print "大字号/图标"; else print "偏低" }')"
  printf '  %s%s%s  %s  %s  %s%s%s  %s\n' \
    "${UI_MUTED}" "$(lab_pad "药丸文字" 10)" "${UI_RESET}" "$(lab_pad "UI_HL_FG/BG" 15)" \
    "$(lab_pad "${hl_fg_land} on ${hl_bg_land}" 20)" \
    "$(awk -v r="${hl_ratio}" 'BEGIN { print (r >= 4.5 ? "" : "\033[33m") }')" \
    "$(lab_pad "${hl_ratio}" 6)" "${UI_RESET}" "${hl_verdict}"
  printf '%s  判据：≥4.5 可作正文（WCAG AA）；3.0-4.5 只够大字号/图标；<3.0 偏低。\n' "${UI_MUTED}"
  printf '  选中方框只要求「比未选中方框显眼」，不要求可读文本级对比度。%s\n' "${UI_RESET}"
}

# 一套方案的完整展示。
lab_show() {
  local name="${1:-}" w="${2:-100}" i
  lab_apply "${name}" || { printf '未知方案：%s\n' "${name}" >&2; return 1; }
  i="$(lab_index "${name}")" || return 1
  printf '\n'
  _lab_rule 72
  printf '%s%s  %d/%d  %s  ——  %s%s\n' \
    "$(core_c_bold)" "${UI_ACCENT}" "$(( i + 1 ))" "${#LAB_NAMES[@]}" "${name}" "${LAB_LABELS[$i]}" "${UI_RESET}"
  printf '%s来源：%s%s\n' "${UI_MUTED}" "${LAB_SOURCES[$i]}" "${UI_RESET}"
  printf '%s类型：%s（%s）    配色基准背景：%s%s\n' \
    "${UI_MUTED}" "$([[ "${LAB_VARIANTS[$i]}" == "light" ]] && printf '浅色' || printf '深色')" \
    "${LAB_VARIANTS[$i]}" "${LAB_BG_CALC}" "${UI_RESET}"
  printf '%s处置：%s%s\n' "${UI_MUTED}" "${LAB_NOTES[$i]}" "${UI_RESET}"
  _lab_rule 72

  _lab_show_home "${w}"
  _lab_show_roles
  _lab_show_map
  _lab_show_contrast
}

# 只列方案名。
lab_list() {
  local i st
  printf '共 %d 套候选方案（现有 dark / light / nord / gruvbox / high-contrast 均不改动）：\n' \
    "${#LAB_NAMES[@]}"
  for i in "${!LAB_NAMES[@]}"; do
    if [[ "${LAB_NAMES[$i]}" == "nord-frost" || "${LAB_NAMES[$i]}" == "gruvbox-warm" ]]; then
      st="新增·与现有同名主题同源"
    else
      st="新增"
    fi
    printf '  %-13s %-20s %-5s %s\n' "${LAB_NAMES[$i]}" "${LAB_LABELS[$i]}" \
      "$([[ "${LAB_VARIANTS[$i]}" == "light" ]] && printf '浅色' || printf '深色')" "${st}"
  done
}

# ===========================================================================
# 6. 自检
# ===========================================================================
#
# 五类断言：
#   1) 每个角色的 SGR 是合法 CSI 序列（正好是 `ESC [ 数字;... m`），且剥掉之后显示宽度为 0
#      —— 颜色绝不能吃掉列宽，否则产品的宽度引擎会算错；
#   2) 所有颜色索引都在 0..255，且**不含真彩色**（本项目只支持 38;5;N / 48;5;N）；
#   3) **除 UI_HL / UI_HL_FG 外，任何角色都不得出现背景色 48;5;**（选中态不许有填充块）；
#   4) 每套方案在每个宽度下渲染出的每一行都 ≤ UI_COLS（响应式硬不变量）；
#   5) 换配色不得改变几何：任意两套方案在同一宽度下的逐行显示宽度必须完全一致，
#      且与「全无色」渲染也一致。

LAB_CHECK_WIDTHS=(16 20 24 40 60 79 80 100 120 200)

# 剥 ANSI（结果写 _LAB_PLAIN）。
# 必须用最短匹配逐个剥：`${s//$'\033'\[[0-9;]*[a-zA-Z]/}` 里的 glob `*` 是贪婪的，
# 会从第一个转义一路吞到行尾，整行被删空、宽度恒为 0 —— 所有宽度断言都会「静默地永远通过」。
_lab_strip() {
  local s="${1:-}" out="" rest
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"
    s="${s#*$'\033['}"
    rest="${s#*[a-zA-Z]}"
    if [[ "${rest}" == "${s}" ]]; then
      # 后面没有终止字母（不该发生）：直接放弃，避免死循环。
      s=""
      break
    fi
    s="${rest}"
  done
  _LAB_PLAIN="${out}${s}"
}

# 从 SGR 串里抠出所有 38;5;N / 48;5;N 的 N，写全局 LAB_IDX_LIST（空格分隔）。
_lab_sgr_indices() {
  local s="${1:-}" out=""
  while [[ "${s}" =~ (38|48)\;5\;([0-9]+) ]]; do
    out+="${BASH_REMATCH[2]} "
    s="${s#*"${BASH_REMATCH[0]}"}"
  done
  LAB_IDX_LIST="${out% }"
}

# 角色是否属于「铺满型」（唯一允许带背景色的两个）。
_lab_is_fill_role() {
  local r="${1:-}" x
  for x in "${LAB_FILL_ROLES[@]}"; do
    [[ "${x}" == "${r}" ]] && return 0
  done
  return 1
}

# 检查一个角色的 SGR。问题数写全局 _LAB_ROLE_BAD，明细直接打印。
_lab_check_role_sgr() {
  local who="$1" role="$2" sgr idxs n
  _LAB_ROLE_BAD=0
  lab_role_sgr "${role}"; sgr="${LAB_SGR}"
  if [[ -z "${sgr}" ]]; then
    printf '  FAIL [%s] 角色 %s 为空\n' "${who}" "${role}"
    _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
    return 0
  fi
  if [[ ! "${sgr}" =~ ^$'\033'\[[0-9\;]*m$ ]]; then
    printf '  FAIL [%s] 角色 %s 的 SGR 不是合法 CSI 序列：%q\n' "${who}" "${role}" "${sgr}"
    _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
  fi
  if [[ "${sgr}" == *"38;2;"* || "${sgr}" == *"48;2;"* ]]; then
    printf '  FAIL [%s] 角色 %s 用了真彩色（本项目只支持 256 色）：%q\n' "${who}" "${role}" "${sgr}"
    _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
  fi
  # 选中态不许有填充块：除 UI_HL / UI_HL_FG 外任何角色都不许带背景色。
  if [[ "${sgr}" == *"48;5;"* ]] && ! _lab_is_fill_role "${role}"; then
    printf '  FAIL [%s] 角色 %s 带了背景色（只有 UI_HL / UI_HL_FG 允许铺底）：%q\n' \
      "${who}" "${role}" "${sgr}"
    _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
  fi
  _lab_sgr_indices "${sgr}"
  idxs="${LAB_IDX_LIST}"
  if [[ -z "${idxs}" ]]; then
    printf '  FAIL [%s] 角色 %s 的 SGR 里没有任何 38;5;N / 48;5;N 颜色：%q\n' \
      "${who}" "${role}" "${sgr}"
    _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
  fi
  for n in ${idxs}; do
    if (( n < 0 || n > 255 )); then
      printf '  FAIL [%s] 角色 %s 的颜色索引越界：%s\n' "${who}" "${role}" "${n}"
      _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
    fi
  done
  # 剥掉 ANSI 之后必须什么都不剩（宽度 0）——证明宽度引擎不会被颜色干扰。
  _lab_strip "${sgr}"
  if [[ -n "${_LAB_PLAIN}" ]]; then
    printf '  FAIL [%s] 角色 %s 剥色后仍剩 %q\n' "${who}" "${role}" "${_LAB_PLAIN}"
    _LAB_ROLE_BAD=$(( _LAB_ROLE_BAD + 1 ))
  fi
}

# 渲染一帧并量宽：逐行剥色后的显示宽度写 _LAB_WIDTHS，行内容写 _LAB_LINES。
_lab_frame() {
  local name="$1" w="$2" line
  lab_apply "${name}"
  _LAB_LINES=(); _LAB_WIDTHS=()
  while IFS= read -r line; do
    _lab_strip "${line}"
    _LAB_LINES+=("${_LAB_PLAIN}")
    _core_width "${_LAB_PLAIN}"
    _LAB_WIDTHS+=("${_CORE_W}")
  done < <(lab_render_home "${w}")
}

# 负向对照：证明上面这些检查器「失败得出来」。
# 不会失败的检查等于没检查 —— 这一节故意制造坏输入。
_lab_check_selftest() {
  local bad=0 saved
  # 1) 索引越界必须被 _lab_check_role_sgr 抓到
  saved="${UI_ACCENT}"
  UI_ACCENT=$'\033[38;5;300m'
  _lab_check_role_sgr "selftest" "accent" >/dev/null 2>&1
  (( _LAB_ROLE_BAD > 0 )) || { printf '  反向对照失败：越界索引 300 未被判失败\n'; bad=1; }
  UI_ACCENT="${saved}"

  # 2) 真彩色必须被抓到
  saved="${UI_TEXT}"
  UI_TEXT=$'\033[38;2;255;0;0m'
  _lab_check_role_sgr "selftest" "text" >/dev/null 2>&1
  (( _LAB_ROLE_BAD > 0 )) || { printf '  反向对照失败：真彩色未被判失败\n'; bad=1; }
  UI_TEXT="${saved}"

  # 3) 非铺满角色带背景色必须被抓到（选中态不许有填充块）
  saved="${UI_SEL}"
  UI_SEL=$'\033[38;5;15;48;5;24m'
  _lab_check_role_sgr "selftest" "sel" >/dev/null 2>&1
  (( _LAB_ROLE_BAD > 0 )) || { printf '  反向对照失败：UI_SEL 带背景色未被判失败\n'; bad=1; }
  #    反过来：UI_HL 带背景色是**合法**的，不许误报
  saved_h="${UI_HL}"
  UI_HL=$'\033[38;5;15;48;5;24m'
  _lab_check_role_sgr "selftest" "hl" >/dev/null 2>&1
  (( _LAB_ROLE_BAD == 0 )) || { printf '  反向对照失败：UI_HL 的背景色被误判为违规\n'; bad=1; }
  UI_SEL="${saved}"; UI_HL="${saved_h}"

  # 4) 剥 ANSI 必须真的生效：剥错的话带色行会塌成 0 列，宽度断言全部静默通过
  _lab_strip "$(core_sgr 244)▸$(core_sgr 252) 作业 DDL$(core_c_reset)"
  _core_width "${_LAB_PLAIN}"
  if (( _CORE_W != 10 )); then
    printf '  反向对照失败：带色行剥后宽度应为 10，实得 %d（strip 坏了，检查无效）\n' "${_CORE_W}"
    bad=1
  fi

  # 5) 宽度链路本身要能量出超宽
  local wide
  printf -v wide '%*s' 201 ''
  _core_width "${wide}"
  (( _CORE_W > 200 )) || { printf '  反向对照失败：201 个空格未被量成超宽\n'; bad=1; }

  (( bad == 0 )) && printf '  反向对照通过：越界索引 / 真彩色 / 越权背景 / strip / 宽度链都能真的报错。\n'
  return "${bad}"
}

lab_check() {
  local bad=0 i name role w ref first
  local -a refw=() curw=()
  local j len
  printf '\n配色自检\n'
  _lab_rule 60
  printf '  0) 检查器反向对照\n'
  _lab_check_selftest || bad=$(( bad + 1 ))

  printf '  1) 角色 SGR 合法 + 索引 0..255 + 除 UI_HL/UI_HL_FG 外无背景色（%d 套 × %d 角色）\n' \
    "${#LAB_NAMES[@]}" "${#LAB_UI_ROLES[@]}"
  for name in "${LAB_NAMES[@]}"; do
    lab_apply "${name}" || { printf '  FAIL 未知方案 %s\n' "${name}"; bad=$(( bad + 1 )); continue; }
    for role in "${LAB_UI_ROLES[@]}"; do
      _lab_check_role_sgr "${name}" "${role}"
      bad=$(( bad + _LAB_ROLE_BAD ))
    done
  done

  printf '  2) 帧宽 <= UI_COLS（%d 套 × %d 个宽度）\n' "${#LAB_NAMES[@]}" "${#LAB_CHECK_WIDTHS[@]}"
  for name in "${LAB_NAMES[@]}"; do
    for w in "${LAB_CHECK_WIDTHS[@]}"; do
      _lab_frame "${name}" "${w}"
      for i in "${!_LAB_WIDTHS[@]}"; do
        (( _LAB_WIDTHS[i] == 0 )) && continue
        if (( _LAB_WIDTHS[i] > w )); then
          printf '  FAIL [%s] 宽度 %d 的第 %d 行实测 %d 列\n  　|%s|\n' \
            "${name}" "${w}" "$(( i + 1 ))" "${_LAB_WIDTHS[i]}" "${_LAB_LINES[$i]}"
          bad=$(( bad + 1 ))
        fi
      done
    done
  done

  printf '  3) 换配色不改几何（跨方案逐行等宽 + 与无色渲染等宽）\n'
  for w in "${LAB_CHECK_WIDTHS[@]}"; do
    refw=(); ref=""
    for name in "${LAB_NAMES[@]}"; do
      _lab_frame "${name}" "${w}"
      curw=("${_LAB_WIDTHS[@]}")
      len="${#curw[@]}"
      if [[ -z "${ref}" ]]; then
        ref="${name}"; refw=("${curw[@]}"); continue
      fi
      if (( len != ${#refw[@]} )); then
        printf '  FAIL 宽度 %d：%s 与 %s 的行数不同（%d vs %d）\n' \
          "${w}" "${ref}" "${name}" "${#refw[@]}" "${len}"
        bad=$(( bad + 1 ))
        continue
      fi
      for (( j = 0; j < len; j++ )); do
        if (( curw[j] != refw[j] )); then
          printf '  FAIL 宽度 %d 第 %d 行：%s 为 %d 列，%s 为 %d 列\n' \
            "${w}" "$(( j + 1 ))" "${ref}" "${refw[j]}" "${name}" "${curw[j]}"
          bad=$(( bad + 1 ))
        fi
      done
    done
    # 与「全无色」渲染对照：颜色必须完全不影响几何。
    local s_a="${UI_ACCENT}" s_t="${UI_TEXT}" s_m="${UI_MUTED}" s_b="${UI_BORDER}"
    local s_h="${UI_HL}" s_hf="${UI_HL_FG}" s_ok="${UI_SUCCESS}" s_wn="${UI_WARNING}"
    local s_dg="${UI_DANGER}" s_pp="${UI_PURPLE}" s_ti="${UI_TITLE}" s_sl="${UI_SEL}"
    local s_sb="${UI_SEL_BORDER}"
    UI_ACCENT=""; UI_TEXT=""; UI_MUTED=""; UI_BORDER=""; UI_HL=""; UI_HL_FG=""
    UI_SUCCESS=""; UI_WARNING=""; UI_DANGER=""; UI_PURPLE=""; UI_TITLE=""
    UI_SEL=""; UI_SEL_BORDER=""
    _lab_frame "${LAB_NAMES[0]}" "${w}"
    curw=("${_LAB_WIDTHS[@]}")
    UI_ACCENT="${s_a}"; UI_TEXT="${s_t}"; UI_MUTED="${s_m}"; UI_BORDER="${s_b}"
    UI_HL="${s_h}"; UI_HL_FG="${s_hf}"; UI_SUCCESS="${s_ok}"; UI_WARNING="${s_wn}"
    UI_DANGER="${s_dg}"; UI_PURPLE="${s_pp}"; UI_TITLE="${s_ti}"
    UI_SEL="${s_sl}"; UI_SEL_BORDER="${s_sb}"
    lab_apply "${LAB_NAMES[0]}"
    if (( ${#curw[@]} != ${#refw[@]} )); then
      printf '  FAIL 宽度 %d：无色渲染行数与带色不同（%d vs %d）\n' \
        "${w}" "${#curw[@]}" "${#refw[@]}"
      bad=$(( bad + 1 ))
    else
      for (( j = 0; j < ${#curw[@]}; j++ )); do
        if (( curw[j] != refw[j] )); then
          printf '  FAIL 宽度 %d 第 %d 行：无色 %d 列，带色 %d 列 —— 颜色影响了几何\n' \
            "${w}" "$(( j + 1 ))" "${curw[j]}" "${refw[j]}"
          bad=$(( bad + 1 ))
        fi
      done
    fi
  done

  _lab_rule 60
  if (( bad == 0 )); then
    printf '自检通过：0 处问题。\n'
    return 0
  fi
  printf '自检失败：%d 处问题。\n' "${bad}"
  return 1
}

# ===========================================================================
# 7. 入口
# ===========================================================================

lab_usage() {
  printf '用法：bash docs/palette-lab.sh [方案名|all|list|check] [宽度]\n'
  printf '方案名：%s\n' "$(printf '%s ' "${LAB_NAMES[@]}")"
}

lab_main() {
  local target="${1:-all}" width="${2:-}"
  local name i
  if [[ -z "${width}" ]]; then
    width="${LAB_WIDTH:-100}"
  fi
  if [[ ! "${width}" =~ ^[0-9]+$ ]] || (( width < 8 )); then
    printf '宽度参数必须是 >= 8 的整数，实得：%s\n' "${width}" >&2
    return 2
  fi
  case "${target}" in
    list) lab_list; return 0 ;;
    check) lab_check; return $? ;;
    all) ;;
    -h|--help|help) lab_usage; return 0 ;;
    *)
      if ! lab_has_palette "${target}"; then
        printf '未知方案：%s\n' "${target}" >&2
        lab_usage >&2
        return 2
      fi
      ;;
  esac

  printf '%s配色方案展示台%s —— 共 %d 套**新增**候选（现有 dark / light / nord / gruvbox / high-contrast 均不改动）\n' \
    "$(core_c_bold)" "$(core_c_reset)" "${#LAB_NAMES[@]}"
  printf '宽度 %s 列；图标档位 %s（BUPTY_FORCE_ICONS）。颜色全部是 256 色（38;5;N / 48;5;N），真彩色样本仅用于对照。\n' \
    "${width}" "${ICON_MODE}"

  if [[ "${target}" == "all" ]]; then
    for name in "${LAB_NAMES[@]}"; do
      lab_show "${name}" "${width}"
    done
  else
    lab_show "${target}" "${width}"
  fi
  printf '\n'
  _lab_rule 72
  printf '%s看自检：bash docs/palette-lab.sh check%s\n' "$(core_c_bold)" "$(core_c_reset)"
  return 0
}

# 只有直接执行时才跑 main；被 tests/unit_palette.sh source 时只加载函数与色表。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  lab_main "$@"
  exit $?
fi
