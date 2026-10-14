#!/usr/bin/env bash
# ui.sh —— TUI 渲染原语：主题配色、终端模式、清屏、盒子、按键读取、文本输入。

if [[ -n "${_BUPTY_UI_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_UI_LOADED=1

# ---------------------------------------------------------------------------
# 主题
# ---------------------------------------------------------------------------

# 主题角色 SGR 前缀变量：UI_ACCENT / UI_TEXT / UI_MUTED / UI_BORDER /
# UI_HL(选中背景) / UI_HL_FG(选中前景) / UI_SEL(选中前景·无背景) /
# UI_SUCCESS / UI_WARNING / UI_DANGER / UI_PURPLE / UI_TITLE / UI_BG(整屏底色)。
# 硬约束：每套主题都必须完整定义这 13 个角色——首页卡片、7 个视图、状态栏全读它们，
# 缺任意一个就会渲染出无色或串色的行。全部经由 core_sgr 构造，不硬编码 ANSI。
#
# UI_HL / UI_HL_FG **含背景色**（core_sgr 的第 2 个数字参数），只用于「整行铺满」的
# 反显选区（设置页列表、各视图选中行、ui_select_option）。**不要把它俩当纯前景色用**：
# 它会给一小段文本刷上背景，在卡片/单元格里表现成一块游离的色块（首页选中卡片曾这样
# 漏出 9 列蓝底）。需要「选中态的强调前景、且不带背景」时一律用 UI_SEL。
#
# UI_BG 是第 13 个角色：本主题**整屏铺的底色**（core_sgr 第 1 个数字参数留空、
# 第 2 个数字参数给 256 色背景索引，产出纯 \033[48;5;N m）。它是「主题自带底色」的载体：
# tui_render 起手先发它再擦屏（依赖 BCE，让擦屏动作本身带底色），UI_RESET 每次重置后
# 立刻恢复它——几百处 ui_paint 调用点因此无需逐个改动就都画在这套底上。产品一度 12 个
# 角色全是前景色、画在用户终端自己的底色上，浅色系（light/latte/rosepine）落到黑底
# 就不可读；UI_BG 就是修这个的。
UI_ACCENT=""; UI_TEXT=""; UI_MUTED=""; UI_BORDER=""; UI_HL=""; UI_HL_FG=""; UI_SEL=""
UI_SUCCESS=""; UI_WARNING=""; UI_DANGER=""; UI_PURPLE=""; UI_TITLE=""
UI_BG=""
# UI_RESET = 重置 + 立刻恢复本主题底色（ui_theme_apply 里随主题更新）。
# 模块刚加载、还没应用任何主题时 UI_BG 为空，这里先退化成纯 \033[0m——安全默认，
# 保证「没有主题时」的一切输出与改动前逐字节一致。
UI_RESET="$(core_c_reset)"

# 具名主题清单——这里是**唯一权威来源**：设置页候选、next/prev 循环、
# ui_theme_init 的分派三者都必须与它一致。数组顺序即设置页的循环顺序。
UI_THEME_NAMES=(dark light nord gruvbox high-contrast mocha tokyonight kanagawa latte rosepine)
# 与 UI_THEME_NAMES 一一对应的中文标签（设置页展示用）。
UI_THEME_LABELS=("暗色" "浅色" "Nord" "Gruvbox" "高对比" "Mocha" "Tokyo Night" "Kanagawa" "Latte" "Rose Pine")
# 暗色系主题；未登记的是浅色系（light / latte / rosepine）。只登记名字，不提供判定函数——
# 生产代码里没有任何地方需要「这套主题是不是暗色」，调用方直接查这个数组即可。
UI_THEME_DARK_NAMES=(dark nord gruvbox high-contrast mocha tokyonight kanagawa)
UI_THEME_DEFAULT="dark"
# 当前**已应用**的主题名（由 ui_theme_apply 写入，非用户请求名）。
UI_THEME="${UI_THEME_DEFAULT}"

# 主题名是否在清单内。
ui_theme_valid() {
  local n="${1:-}" t
  for t in "${UI_THEME_NAMES[@]}"; do
    [[ "${n}" == "${t}" ]] && return 0
  done
  return 1
}

# 主题下标；未知返回 -1。
ui_theme_index() {
  local n="${1:-}" i
  for i in "${!UI_THEME_NAMES[@]}"; do
    if [[ "${n}" == "${UI_THEME_NAMES[$i]}" ]]; then
      printf '%s' "${i}"
      return 0
    fi
  done
  printf '%s' "-1"
}

# 主题中文标签；未知退回主题名本身。
ui_theme_label() {
  local n="${1:-}" i
  i="$(ui_theme_index "${n}")"
  if (( i >= 0 )); then
    printf '%s' "${UI_THEME_LABELS[$i]}"
  else
    printf '%s' "${n}"
  fi
}

# 循环取下一个主题名（未知从清单首项开始）。
ui_theme_next() {
  local n="${1:-}" i
  i="$(ui_theme_index "${n}")"
  if (( i < 0 )); then
    i=0
  else
    i=$(( (i + 1) % ${#UI_THEME_NAMES[@]} ))
  fi
  printf '%s' "${UI_THEME_NAMES[$i]}"
}

# 循环取上一个主题名（未知从清单首项开始）。
ui_theme_prev() {
  local n="${1:-}" i total="${#UI_THEME_NAMES[@]}"
  i="$(ui_theme_index "${n}")"
  if (( i < 0 )); then
    i=0
  else
    i=$(( (i + total - 1) % total ))
  fi
  printf '%s' "${UI_THEME_NAMES[$i]}"
}

# --- 各主题角色表（全部走 core_sgr，256 色） -------------------------------

# dark：用户已认可的默认观感，SGR 值与旧实现逐字节一致，不许改动。
_ui_theme_dark() {
  UI_ACCENT="$(core_sgr 39)"
  UI_TEXT="$(core_sgr 252)"
  UI_MUTED="$(core_sgr 244)"
  UI_BORDER="$(core_sgr 239)"
  UI_HL="$(core_sgr 0 24 bold)"
  UI_HL_FG="$(core_sgr 15 24 bold)"
  UI_SEL="$(core_sgr 81 bold)"      # 选中前景·无背景：亮蓝 (#5FD7FF)，深底上比 accent 更醒目
  UI_SUCCESS="$(core_sgr 114)"
  UI_WARNING="$(core_sgr 215)"
  UI_DANGER="$(core_sgr 203)"
  UI_PURPLE="$(core_sgr 135)"
  UI_TITLE="$(core_sgr 39 bold)"
  UI_BG="$(core_sgr "" 233)"        # 整屏底色：极深近黑 #121212（原观感是终端黑，别偏离太远）
}

# light：浅色终端专用（原文案的起点）。深色文字压白底，选区反显用亮蓝底黑字。
_ui_theme_light() {
  UI_ACCENT="$(core_sgr 26)"
  UI_TEXT="$(core_sgr 235)"
  UI_MUTED="$(core_sgr 242)"
  UI_BORDER="$(core_sgr 250)"
  UI_HL="$(core_sgr 0 33 bold)"
  UI_HL_FG="$(core_sgr 17 33 bold)"
  UI_SEL="$(core_sgr 20 bold)"       # 选中前景·无背景：深蓝 (#0000D7)，白底可读
  UI_SUCCESS="$(core_sgr 28)"
  UI_WARNING="$(core_sgr 130)"    # 深琥珀 #AF5F00 → (175,95,0)，白底 4.71（原 208 仅 2.41，太浅）
  UI_DANGER="$(core_sgr 160)"
  UI_PURPLE="$(core_sgr 91)"
  UI_TITLE="$(core_sgr 26 bold)"
  UI_BG="$(core_sgr "" 231)"        # 整屏底色：纯白 #FFFFFF（深字压白底）
}

# nord：取自 Nord 极夜调色板（Polar Night / Frost / Aurora），映射到最近的 256 色。
_ui_theme_nord() {
  UI_ACCENT="$(core_sgr 110)"        # Frost #88C0D0 → (135,175,215)
  UI_TEXT="$(core_sgr 253)"          # Snow Storm #D8DEE9 → 灰阶 218
  UI_MUTED="$(core_sgr 247)"         # 中性灰（灰阶 158），深底对比度 4.93
  UI_BORDER="$(core_sgr 240)"        # Polar Night #4C566A → 灰阶 88
  UI_HL="$(core_sgr 15 60 bold)"     # 白字 + 石板蓝底 (95,95,135)
  UI_HL_FG="$(core_sgr 15 60 bold)"
  UI_SEL="$(core_sgr 117 bold)"      # 选中前景·无背景：亮霜蓝 #87D7FF（accent 提亮）
  UI_SUCCESS="$(core_sgr 108)"       # Aurora green #A3BE8C → (135,175,135)
  UI_WARNING="$(core_sgr 186)"       # Aurora yellow #EBCB8B → (215,215,135)
  UI_DANGER="$(core_sgr 131)"        # Aurora red #BF616A → (175,95,95)
  UI_PURPLE="$(core_sgr 139)"        # Aurora purple #B48EAD → (175,135,175)
  UI_TITLE="$(core_sgr 110 bold)"
  UI_BG="$(core_sgr "" 237)"        # 整屏底色：nord0 #2E3440 → 256 落点 #3A3A3A
}

# gruvbox：取自 Gruvbox Dark 调色板（暖色复古），映射到最近的 256 色。
_ui_theme_gruvbox() {
  UI_ACCENT="$(core_sgr 109)"        # aqua/blue #83A598 → (135,175,175)
  UI_TEXT="$(core_sgr 223)"          # fg #EBDBB2 → (255,215,175)
  UI_MUTED="$(core_sgr 246)"         # gray 灰阶 148，深底对比度 4.99
  UI_BORDER="$(core_sgr 239)"        # bg2 #504945 → 灰阶 78
  UI_HL="$(core_sgr 223 238 bold)"   # 奶油字 + 深灰底 (68,68,68)
  UI_HL_FG="$(core_sgr 223 238 bold)"
  UI_SEL="$(core_sgr 116 bold)"      # 选中前景·无背景：亮青 #87D7D7（accent 提亮）
  UI_SUCCESS="$(core_sgr 142)"       # green #B8BB26 → (175,175,0)
  UI_WARNING="$(core_sgr 214)"       # yellow #FABD2F → (255,175,0)
  UI_DANGER="$(core_sgr 203)"        # red #FB4934 → (255,95,95)
  UI_PURPLE="$(core_sgr 174)"        # purple #D3869B → (215,135,135)
  UI_TITLE="$(core_sgr 109 bold)"
  UI_BG="$(core_sgr "" 235)"        # 整屏底色：bg0 #282828 → 256 落点 #262626
}

# high-contrast：低视力友好。全用最亮/最饱和的 16 色基调，正文纯白、次要色也不压暗。
_ui_theme_high_contrast() {
  UI_ACCENT="$(core_sgr 51)"         # 亮青 #00FFFF
  UI_TEXT="$(core_sgr 231)"          # 纯白 #FFFFFF
  UI_MUTED="$(core_sgr 250)"         # 亮灰 #BCBCBC（不做低对比压暗）
  UI_BORDER="$(core_sgr 244)"        # 中灰
  UI_HL="$(core_sgr 0 226 bold)"     # 黑字 + 亮黄底（最高对比的反显）
  UI_HL_FG="$(core_sgr 0 226 bold)"
  UI_SEL="$(core_sgr 51 bold)"       # 选中前景·无背景：亮青 #00FFFF 加粗（与 accent 同色，纯前景）
  UI_SUCCESS="$(core_sgr 46)"        # 亮绿 #00FF00
  UI_WARNING="$(core_sgr 226)"       # 亮黄 #FFFF00
  UI_DANGER="$(core_sgr 196)"        # 亮红 #FF0000
  UI_PURPLE="$(core_sgr 201)"        # 亮品红 #FF00FF
  UI_TITLE="$(core_sgr 51 bold)"
  UI_BG="$(core_sgr "" 16)"         # 整屏底色：纯黑 #000000（白字最大化对比）
}

# mocha：取自 Catppuccin Mocha（TUI 社区事实标准的柔和暗色），映射到最近的 256 色。
_ui_theme_mocha() {
  UI_ACCENT="$(core_sgr 111)"        # blue #89B4FA → (135,175,255)
  UI_TEXT="$(core_sgr 189)"          # text #CDD6F4 → (215,215,255)
  UI_MUTED="$(core_sgr 103)"         # overlay2 #9399B2 → (135,135,175)，深底对比度 4.78
  UI_BORDER="$(core_sgr 239)"        # surface1 #45475A → 灰阶 78
  UI_HL="$(core_sgr 233 111 bold)"   # 深字 #11111B + 蓝底 (135,175,255)
  UI_HL_FG="$(core_sgr 233 111 bold)"
  UI_SEL="$(core_sgr 147 bold)"      # 选中前景·无背景：lavender #B4BEFE → (175,175,255)
  UI_SUCCESS="$(core_sgr 151)"       # green #A6E3A1 → (175,215,175)
  UI_WARNING="$(core_sgr 223)"       # yellow #F9E2AF → (255,215,175)
  UI_DANGER="$(core_sgr 211)"        # red #F38BA8 → (255,135,175)
  UI_PURPLE="$(core_sgr 183)"        # mauve #CBA6F7 → (215,175,255)
  UI_TITLE="$(core_sgr 111 bold)"
  UI_BG="$(core_sgr "" 235)"        # 整屏底色：base #1E1E2E → 256 落点 #262626
}

# tokyonight：取自 Tokyo Night Storm（folke/tokyonight.nvim），冷蓝底 + 霓虹强调。
_ui_theme_tokyonight() {
  UI_ACCENT="$(core_sgr 111)"        # blue #7AA2F7 → (135,175,255)
  UI_TEXT="$(core_sgr 153)"          # fg #C0CAF5 → (175,215,255)
  UI_MUTED="$(core_sgr 146)"         # fg_dark #A9B1D6 → (175,175,215)，深底对比度 6.89
  UI_BORDER="$(core_sgr 239)"        # terminal_black #414868 → 灰阶 78
  UI_HL="$(core_sgr 234 111 bold)"   # 深字 #1A1B26 + 蓝底 (135,175,255)
  UI_HL_FG="$(core_sgr 234 111 bold)"
  UI_SEL="$(core_sgr 117 bold)"      # 选中前景·无背景：cyan #7DCFFF → (135,215,255)
  UI_SUCCESS="$(core_sgr 149)"       # green #9ECE6A → (175,215,95)
  UI_WARNING="$(core_sgr 179)"       # yellow #E0AF68 → (215,175,95)
  UI_DANGER="$(core_sgr 210)"        # red #F7768E → (255,135,135)
  UI_PURPLE="$(core_sgr 141)"        # magenta #BB9AF7 → (175,135,255)
  UI_TITLE="$(core_sgr 111 bold)"
  UI_BG="$(core_sgr "" 236)"        # 整屏底色：bg #24283B → 256 落点 #303030
}

# kanagawa：取自 Kanagawa Wave（rebelot/kanagawa.nvim），日式墨色。
_ui_theme_kanagawa() {
  UI_ACCENT="$(core_sgr 110)"        # crystalBlue #7E9CD8 → (135,175,215)
  UI_TEXT="$(core_sgr 187)"          # fujiWhite #DCD7BA → (215,215,175)
  UI_MUTED="$(core_sgr 242)"         # fujiGray #727169 → 灰阶 108，深底对比度 3.11（卡 UI_MUTED≥3.0 边缘）
  UI_BORDER="$(core_sgr 59)"         # sumiInk4 #54546D → (95,95,95)
  UI_HL="$(core_sgr 235 110 bold)"   # 墨字 #1F1F28 + crystalBlue 底 (135,175,215)
  UI_HL_FG="$(core_sgr 235 110 bold)"
  UI_SEL="$(core_sgr 110 bold)"      # 选中前景·无背景：springBlue #7FB4CA → (135,175,215)，与 accent 同索引
  UI_SUCCESS="$(core_sgr 107)"       # springGreen #98BB6C → (135,175,95)
  UI_WARNING="$(core_sgr 180)"       # carpYellow #E6C384 → (215,175,135)
  UI_DANGER="$(core_sgr 168)"        # waveRed #E46876 → (215,95,135)
  UI_PURPLE="$(core_sgr 103)"        # oniViolet #957FB8 → (135,135,175)
  UI_TITLE="$(core_sgr 110 bold)"
  UI_BG="$(core_sgr "" 234)"        # 整屏底色：sumiInk1 #1F1F28 的 256 落点 #262626 会让
                                    # UI_MUTED(#6C6C6C) 掉到 2.88<3.0，故改取更深的 #1C1C1C
                                    # （落点 234，muted 回到 3.24）——「换底色」不换前景角色。
}

# latte：取自 Catppuccin Latte（Mocha 的浅色对应），浅色终端用。
_ui_theme_latte() {
  UI_ACCENT="$(core_sgr 27)"         # blue #1E66F5 → (0,95,255)
  UI_TEXT="$(core_sgr 240)"          # text #4C4F69 → 灰阶 88，白底对比度 7.11
  UI_MUTED="$(core_sgr 243)"         # subtext0 #6C6F85 → 灰阶 118，白底对比度 4.54
  UI_BORDER="$(core_sgr 248)"        # overlay0 #9CA0B0 → 灰阶 168
  UI_HL="$(core_sgr 231 27 bold)"    # 白字 + 蓝底 (0,95,255)
  UI_HL_FG="$(core_sgr 231 27 bold)"
  UI_SEL="$(core_sgr 27 bold)"       # 选中前景·无背景：复用 blue（mauve 落点白底仅 4.11，AA 不过）
  UI_SUCCESS="$(core_sgr 70)"        # green #40A02B → (95,175,0)，白底 2.76（256 色分辨率上限）
  UI_WARNING="$(core_sgr 172)"       # yellow #DF8E1D → (215,135,0)，白底 2.86
  UI_DANGER="$(core_sgr 161)"        # red #D20F39 → (215,0,95)，白底 5.18
  UI_PURPLE="$(core_sgr 99)"         # mauve #8839EF → (135,95,255)，白底 4.11
  UI_TITLE="$(core_sgr 27 bold)"
  UI_BG="$(core_sgr "" 231)"        # 整屏底色：纯白 #FFFFFF（沿用实验台最坏底色口径；
                                    # 若用 base #EFF1F5 落点 #EEEEEE，UI_SEL #005FFF 会掉到 4.44<4.5）
}

# rosepine：取自 Rosé Pine Dawn，奶油白底 + 灰紫墨，浅色终端用。
_ui_theme_rosepine() {
  UI_ACCENT="$(core_sgr 24)"         # pine #286983 → (0,95,135)
  UI_TEXT="$(core_sgr 60)"           # text #575279 → (95,95,135)，白底对比度 6.05
  UI_MUTED="$(core_sgr 244)"         # subtle #797593 → 灰阶 128，白底对比度 3.95
  UI_BORDER="$(core_sgr 252)"        # highlightHigh #CECACD → 灰阶 208
  UI_HL="$(core_sgr 255 24 bold)"    # 奶油字 #FAF4ED + pine 底 (0,95,135)
  UI_HL_FG="$(core_sgr 255 24 bold)"
  UI_SEL="$(core_sgr 24 bold)"       # 选中前景·无背景：复用 pine（iris 白底仅 3.79，AA 不过）
  UI_SUCCESS="$(core_sgr 67)"        # foam #56949F → (95,135,175)，白底 3.77
  UI_WARNING="$(core_sgr 179)"       # gold #EA9D34 → (215,175,95)，白底 2.06
  UI_DANGER="$(core_sgr 132)"        # love #B4637A → (175,95,135)，白底 4.37
  UI_PURPLE="$(core_sgr 103)"        # iris #907AA9 → (135,135,175)，白底 3.43
  UI_TITLE="$(core_sgr 24 bold)"
  UI_BG="$(core_sgr "" 231)"        # 整屏底色：纯白 #FFFFFF（沿用实验台最坏底色口径，深字压白底）
}

# 应用一套主题。未知主题名安全退回默认主题，绝不会留下空的角色变量。
ui_theme_apply() {
  local name="${1:-}"
  ui_theme_valid "${name}" || name="${UI_THEME_DEFAULT}"
  case "${name}" in
    dark) _ui_theme_dark ;;
    light) _ui_theme_light ;;
    nord) _ui_theme_nord ;;
    gruvbox) _ui_theme_gruvbox ;;
    high-contrast) _ui_theme_high_contrast ;;
    mocha) _ui_theme_mocha ;;
    tokyonight) _ui_theme_tokyonight ;;
    kanagawa) _ui_theme_kanagawa ;;
    latte) _ui_theme_latte ;;
    rosepine) _ui_theme_rosepine ;;
    *)
      # 理论上不可达（上面已校验过）；兜底仍按默认主题着色，避免空变量。
      _ui_theme_dark
      name="${UI_THEME_DEFAULT}"
      ;;
  esac
  UI_THEME="${name}"
  # UI_RESET 必须随主题更新：它是「重置 + 立刻恢复本主题底色」，底色一变它就得变。
  # 各主题函数已把 UI_BG 填好；UI_BG 为空（理论上只会在尚未应用主题时出现）则退化成
  # 纯 \033[0m，保证「没有主题时」的输出与改动前逐字节一致。
  if [[ -n "${UI_BG}" ]]; then
    UI_RESET="$(core_c_reset)${UI_BG}"
  else
    UI_RESET="$(core_c_reset)"
  fi
}

# 解析生效主题名，优先级：BUPTY_THEME 环境变量 > settings.json 的 theme > 默认。
# settings.sh 可能尚未加载（lib/ui.sh 允许被单独 source），用 declare -F 守卫。
_ui_resolve_theme() {
  local v=""
  if [[ -n "${BUPTY_THEME:-}" ]]; then
    printf '%s' "${BUPTY_THEME}"
    return 0
  fi
  if declare -F settings_get >/dev/null 2>&1; then
    v="$(settings_get theme 2>/dev/null)" || v=""
    if [[ -n "${v}" && "${v}" != "null" ]]; then
      printf '%s' "${v}"
      return 0
    fi
  fi
  printf '%s' "${UI_THEME_DEFAULT}"
}

# 初始化主题。可显式传主题名（测试与设置页即时切换用）；不传则按上面的优先级解析。
# 注意：本函数**自己**读 settings.json——tui_main 里它先于任何显式 load 调用，
# 不能指望调用方提前加载好设置。
ui_theme_init() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    name="$(_ui_resolve_theme)"
  fi
  ui_theme_apply "${name}"
}

# 用指定角色着色文本。
ui_paint() {
  local role="$1" text="$2"
  local prefix=""
  case "${role}" in
    accent) prefix="${UI_ACCENT}" ;;
    text) prefix="${UI_TEXT}" ;;
    muted) prefix="${UI_MUTED}" ;;
    border) prefix="${UI_BORDER}" ;;
    hl) prefix="${UI_HL_FG}" ;;
    sel) prefix="${UI_SEL}" ;;
    success) prefix="${UI_SUCCESS}" ;;
    warning) prefix="${UI_WARNING}" ;;
    danger) prefix="${UI_DANGER}" ;;
    purple) prefix="${UI_PURPLE}" ;;
    title) prefix="${UI_TITLE}" ;;
    bg) prefix="${UI_BG}" ;;
    reset) prefix="${UI_RESET}" ;;
  esac
  printf '%s%s%s' "${prefix}" "${text}" "${UI_RESET}"
}

ui_bold() { printf '\033[1m%s\033[0m' "$1"; }
ui_dim() { printf '\033[2m%s\033[0m' "$1"; }

# ---------------------------------------------------------------------------
# 终端尺寸 / 模式
# ---------------------------------------------------------------------------

UI_ROWS=24
UI_COLS=80
_UI_SAVED_TTY=""

ui_size() {
  local sz=""
  sz="$(stty size 2>/dev/null)" || sz=""
  if [[ -n "${sz}" && "${sz}" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    UI_ROWS="${sz%% *}"
    UI_COLS="${sz##* }"
  fi
}

ui_clear() {
  printf '\033[2J\033[H'
}

# 上移一行并清除（仅 TTY，避免污染管道/快照输出）。
ui_erase_prev_line() {
  if [[ -t 1 ]]; then
    printf '\033[1A\033[2K'
  fi
}

ui_hide_cursor() { printf '\033[?25l'; }
ui_show_cursor() { printf '\033[?25h'; }

# 备用屏幕缓冲区：TUI 帧不污染终端滚动历史，退出时还原原屏幕（同 vim/less）。
# 同时关闭各种鼠标上报模式，避免滚轮产生鼠标转义序列干扰按键。
ui_enter_alt_screen() { printf '\033[?1049h\033[?1000l\033[?1002l\033[?1003l\033[?1006l'; }
# 退出备用屏幕前先发一次 \033[0m：否则当前主题的底色（UI_BG）会跟着还原后的屏幕一起
# 漏到用户 shell 提示符上，把提示符染成主题底色。这里覆盖两条退出路径——tui.sh 的 EXIT
# trap 与任何直接调用本函数的地方——它们都经由这里离开备用屏幕。
ui_exit_alt_screen() { printf '\033[0m\033[?1049l'; }

# 进入 raw 模式（无回显、逐键）。
ui_raw_mode() {
  _UI_SAVED_TTY="$(stty -g 2>/dev/null)" || _UI_SAVED_TTY=""
  stty -echo -icanon min 1 time 0 2>/dev/null || true
}

# 退出 raw 模式。
ui_restore_mode() {
  if [[ -n "${_UI_SAVED_TTY}" ]]; then
    stty "${_UI_SAVED_TTY}" 2>/dev/null || true
    _UI_SAVED_TTY=""
  fi
  ui_show_cursor
}

# ---------------------------------------------------------------------------
# 盒子字符（Unicode / ASCII 回退）
# ---------------------------------------------------------------------------

_UI_BOX_H="─"; _UI_BOX_V="│"
_UI_BOX_TL="┌"; _UI_BOX_TR="┐"; _UI_BOX_BL="└"; _UI_BOX_BR="┘"
_UI_BOX_ML="├"; _UI_BOX_MR="┤"; _UI_BOX_MT="┬"; _UI_BOX_MB="┴"; _UI_BOX_MC="┼"

ui_box_init() {
  # 边框只有在「UTF-8 且 Ambiguous 类确实占 1 列」时才用 Unicode 制表符，否则退 ASCII(+ - |)。
  # ┌─│┐ 与 ▀▄█ 同属 East Asian Ambiguous 宽度类：BUPTY_AMBIG_W=2 时制表符实占 2 列，
  # 而所有布局代码都假设 _UI_BOX_H 占 1 列（_home_render_cards / _home_render_mini /
  # tui.sh 的整行分隔线），不退 ASCII 就会卡片错位并顶破 UI_COLS。
  #
  # 判定必须直接用 BUPTY_AMBIG_W——它才是决定制表符列数的那一个。不要绕道图标子系统的
  # ICON_UNICODE_W：后者有三条路径**不会被设置**（BUPTY_FORCE_ICONS=off、stdout 是 TTY 而
  # stdin 不是、DSR 探测失败/超时，见 lib/icons.sh），届时若 BUPTY_AMBIG_W=2 就会退化成
  # 「Unicode 边框 + 按 1 列布局」的自相矛盾状态：79 列终端渲染出 85 列，且同一卡片内
  # 顶边 76 列、内部 85 列（锯齿 + 溢出）。BUPTY_AMBIG_W 由 core.sh 在加载时初始化为
  # 1 或 2，恒有定义，无需再猜。
  #
  # 两个分支都显式赋值，因此本函数可重复调用（切档测试与运行时重探测都依赖这一点）。
  if ! core_utf8 || (( ${BUPTY_AMBIG_W:-1} == 2 )); then
    _UI_BOX_H="-"; _UI_BOX_V="|"
    _UI_BOX_TL="+"; _UI_BOX_TR="+"; _UI_BOX_BL="+"; _UI_BOX_BR="+"
    _UI_BOX_ML="+"; _UI_BOX_MR="+"; _UI_BOX_MT="+"; _UI_BOX_MB="+"; _UI_BOX_MC="+"
  else
    _UI_BOX_H="─"; _UI_BOX_V="│"
    _UI_BOX_TL="┌"; _UI_BOX_TR="┐"; _UI_BOX_BL="└"; _UI_BOX_BR="┘"
    _UI_BOX_ML="├"; _UI_BOX_MR="┤"; _UI_BOX_MT="┬"; _UI_BOX_MB="┴"; _UI_BOX_MC="┼"
  fi
}

# 顶部边框：┌──── 标题 ─────┐
ui_box_top() {
  local width="$1" title="${2:-}"
  local inner=$((width - 2))
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_TL}"
  if [[ -n "${title}" ]]; then
    local t=" ${title} "
    printf '%s' "${t}"
    local remain=$((inner - $(core_fit_width "${t}") ))
    (( remain < 0 )) && remain=0
    local i
    for ((i = 0; i < remain; i++)); do printf '%s' "${_UI_BOX_H}"; done
  else
    local i
    for ((i = 0; i < inner; i++)); do printf '%s' "${_UI_BOX_H}"; done
  fi
  printf '%s' "${_UI_BOX_TR}"
  printf '%s\n' "${UI_RESET}"
}

# 底边框：└────────────┘
ui_box_bottom() {
  local width="$1"
  local inner=$((width - 2))
  local i
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_BL}"
  for ((i = 0; i < inner; i++)); do printf '%s' "${_UI_BOX_H}"; done
  printf '%s' "${_UI_BOX_BR}"
  printf '%s\n' "${UI_RESET}"
}

# 中间分隔：├────────────┤
ui_box_mid() {
  local width="$1"
  local inner=$((width - 2))
  local i
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_ML}"
  for ((i = 0; i < inner; i++)); do printf '%s' "${_UI_BOX_H}"; done
  printf '%s' "${_UI_BOX_MR}"
  printf '%s\n' "${UI_RESET}"
}

# 一行内容（带左右边框），内容按显示宽度补齐到 width-2。
ui_box_row() {
  local width="$1" text="${2:-}"
  local inner=$((width - 2))
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_V}"
  printf '%s' "${text}"
  printf '%s' "${_UI_BOX_V}"
  printf '%s\n' "${UI_RESET}"
}

# 显示宽度（中文 2 列）。纯 bash，无 fork。
core_fit_width() {
  local s="${1:-}"
  _core_width "${s}"
  printf '%s' "${_CORE_W}"
}

# 居中文本到指定宽度。
ui_center() {
  local width="$1" text="$2"
  local w
  w="$(core_fit_width "${text}")"
  local left=$(( (width - w) / 2 ))
  (( left < 0 )) && left=0
  local i
  for ((i = 0; i < left; i++)); do printf ' '; done
  printf '%s' "${text}"
}

# ---------------------------------------------------------------------------
# 按键读取
# ---------------------------------------------------------------------------

# 读取一个键，返回命名键（UP/DOWN/LEFT/RIGHT/PGUP/PGDN/HOME/END/TAB/ENTER/BACKSPACE/ESC）
# 或原始字符（如 "a"、"1"、"r"）。
# 可选第一个参数为超时秒数（>0 时超时返回 "TIMEOUT"，便于主循环检查 resize）。
ui_read_key() {
  local timeout="${1:-0}" k rest seq seq2 rc
  if [[ "${timeout}" != "0" ]]; then
    IFS= read -r -s -n1 -t "${timeout}" k
    rc=$?
    if (( rc > 128 )); then printf 'TIMEOUT'; return 0; fi
    if (( rc != 0 )); then printf 'EOF'; return 0; fi
  else
    IFS= read -r -s -n1 k || { printf 'EOF'; return 0; }
  fi
  case "${k}" in
    $'\e')
      IFS= read -r -s -n1 -t 0.02 rest 2>/dev/null || rest=""
      if [[ "${rest}" == "[" ]]; then
        IFS= read -r -s -n1 -t 0.02 seq 2>/dev/null || seq=""
        case "${seq}" in
          A) printf 'UP'; return 0 ;;
          B) printf 'DOWN'; return 0 ;;
          C) printf 'RIGHT'; return 0 ;;
          D) printf 'LEFT'; return 0 ;;
          H) printf 'HOME'; return 0 ;;
          F) printf 'END'; return 0 ;;
          '<'|'M')  # 鼠标上报序列（SGR \033[<…M/m 或 X10 \033[M…），忽略。
            local mm
            while IFS= read -r -s -n1 -t 0.02 mm 2>/dev/null; do
              [[ "${mm}" == "M" || "${mm}" == "m" ]] && break
            done
            printf 'IGNORE'; return 0
            ;;
          [0-9])
            IFS= read -r -s -n1 -t 0.02 seq2 2>/dev/null || seq2=""
            if [[ "${seq2}" == "~" ]]; then
              case "${seq}" in
                5) printf 'PGUP'; return 0 ;;
                6) printf 'PGDN'; return 0 ;;
                1|7) printf 'HOME'; return 0 ;;
                4|8) printf 'END'; return 0 ;;
                *) printf 'ESC'; return 0 ;;
              esac
            else
              printf 'ESC'; return 0
            fi
            ;;
          *) printf 'ESC'; return 0 ;;
        esac
      elif [[ "${rest}" == "O" ]]; then
        IFS= read -r -s -n1 -t 0.02 seq 2>/dev/null || seq=""
        case "${seq}" in
          H) printf 'HOME'; return 0 ;;
          F) printf 'END'; return 0 ;;
          *) printf 'ESC'; return 0 ;;
        esac
      else
        printf 'ESC'; return 0
      fi
      ;;
    $'\t') printf 'TAB'; return 0 ;;
    "") printf 'ENTER'; return 0 ;;
    $'\x7f'|$'\x08') printf 'BACKSPACE'; return 0 ;;
    *) printf '%s' "${k}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 文本输入（raw 模式内联编辑）
# ---------------------------------------------------------------------------

# ui_input <提示文本> <默认值> <secret(0|1)> [最大长度]
# 返回 0 并在全局 UI_INPUT_RESULT 存放结果；Esc 取消返回 1。
UI_INPUT_RESULT=""
ui_input() {
  local prompt="$1" default="${2:-}" secret="${3:-0}" maxlen="${4:-128}"
  local buf="${default}" cursor="${#default}" key ch
  local done=0
  while [[ "${done}" -eq 0 ]]; do
    # 重绘提示 + 输入
    printf '\r\033[K'
    printf '%s' "${prompt}"
    if [[ "${secret}" == "1" ]]; then
      local stars=""
      local i
      for ((i = 0; i < ${#buf}; i++)); do stars+="*"; done
      printf '%s' "${stars}"
    else
      printf '%s' "${buf}"
    fi
    key="$(ui_read_key)"
    case "${key}" in
      ENTER) done=1 ;;
      ESC) UI_INPUT_RESULT=""; return 1 ;;
      BACKSPACE)
        if [[ "${cursor}" -gt 0 ]]; then
          buf="${buf:0:cursor-1}${buf:cursor}"
          (( cursor -= 1 ))
        fi
        ;;
      LEFT) (( cursor > 0 )) && (( cursor -= 1 )) ;;
      RIGHT) (( cursor < ${#buf} )) && (( cursor += 1 )) ;;
      *)
        if [[ "${#key}" -eq 1 && "$(printf '%d' "'${key}")" -ge 32 && "${#buf}" -lt "${maxlen}" ]]; then
          buf="${buf:0:cursor}${key}${buf:cursor}"
          (( cursor += 1 ))
        fi
        ;;
    esac
  done
  printf '\r\033[K'
  UI_INPUT_RESULT="${buf}"
  return 0
}

# ---------------------------------------------------------------------------
# 方向键选择菜单（与全 app 的「高亮选中 + ↑↓ 移动 + Enter 确认」一致）
# ---------------------------------------------------------------------------

# ui_select_option "值1|显示1" "值2|显示2" ...（无 "|" 时值=显示）
# ↑↓ 移动焦点、Enter 确认（选中值写入 UI_SELECT_RESULT）、Esc/q 返回非 0。
# 渲染直接写 stdout（当前光标位置），每次重画前上移清掉上一帧选项区。
UI_SELECT_RESULT=""
ui_select_option() {
  local -a opts=("$@")
  local sel=0 key i n="${#opts[@]}" value label
  UI_SELECT_RESULT=""
  [[ "${n}" -eq 0 ]] && return 1
  while :; do
    for ((i = 0; i < n; i++)); do
      label="${opts[$i]#*|}"
      if (( i == sel )); then
        # 选中项：整行背景高亮（与全 app 列表选中一致）。
        printf '\r\033[K %s%s%s\n' "${UI_HL}" "$(core_fit "› ${label}" "$((UI_COLS - 4))")" "${UI_RESET}"
      else
        printf '\r\033[K   %s\n' "$(ui_paint text "${label}")"
      fi
    done
    key="$(ui_read_key)"
    case "${key}" in
      UP) (( sel > 0 )) && (( sel-- )) ;;
      DOWN) (( sel < n - 1 )) && (( sel++ )) ;;
      ENTER)
        value="${opts[$sel]}"
        [[ "${value}" == *\|* ]] && value="${value%%|*}"
        UI_SELECT_RESULT="${value}"
        return 0
        ;;
      ESC|q) return 1 ;;
    esac
    printf '\033[%dA' "${n}"
  done
}
