#!/usr/bin/env bash
# icons.sh —— 首页模块卡片图标：12×12 点阵 + 三种终端渲染模式（half/bg/off）。
#
# 冻结接口（上层 Agent C 照此调用）：
#   ICON_KEYS=(assignments schedule classrooms grades exams public)   # 六个图标键
#   ICON_W=12     # 显示列数（固定 12 列）
#   ICON_H=6      # 显示行数（固定 6 行，与 half/bg/off 三种模式完全一致）
#   ICON_MODE     # 渲染模式：half / bg / off，由 icon_init 探测后确定
#   ICON_UNICODE_W # 本次实测到的「East Asian Ambiguous 宽度类字符」占几列（1 或 2）
#                  # 探测超时/非 TTY/强制 off 时保持未定义，上层据此决定是否退 ASCII 边框
#   ICON_ROWS[0..5] # icon_render 的产出：恰好 6 行
#
#   icon_init                      # 幂等；探测终端并设好 ICON_MODE / ICON_UNICODE_W
#   icon_render <键> [颜色SGR]     # 结果写进全局数组 ICON_ROWS[0..ICON_H-1]
#   icon_plain_row <下标>          # 纯 ASCII 行（无转义/无半块字符），给测试与宽度校验用
#
# 依赖：icon_render / icon_plain_row / icon_grid 自成一体，不依赖 core.sh / ui.sh（可独立 source）。
#       只有 icon_init 例外——它把宽度探测委托给 core.sh 的 core_probe_ambig，见下方说明。
#       颜色一律由调用方传入，本文件不含任何主题色值。

if [[ -n "${_BUPTY_ICONS_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_ICONS_LOADED=1

# ---------------------------------------------------------------------------
# 冻结接口常量
# ---------------------------------------------------------------------------

ICON_KEYS=(assignments schedule classrooms grades exams public)
ICON_W=12
ICON_H=6

# 渲染模式：half（半块字符 ▀▄█，1×2 分辨率）/ bg（背景色空格，1×1）/ off（占位空白）。
# 默认 off：icon_render 在 icon_init 之前被调用时安全占位，不产生任何转义。
ICON_MODE="off"

# icon_render 的产出：全局数组，长度恰好 6，行宽恰好 12 显示列。
ICON_ROWS=()

# SGR 复位串（本文件内部使用，不依赖 core.sh）。
_ICON_RESET=$'\033[0m'

# 当前已加载的点阵（icon_render 时填充）：12 行字符串，每行 12 个 '.'/'#'。
# 注意：不要再为此维护「行数/列数」缓存——_ICON_GRID 的尺寸是常量 ICON_H/ICON_W，
# 而且 ${#_ICON_GRID[0]} 数的是字节/字符数，不是显示列宽（与 ARCHITECTURE.md 的约定相悖）。
_ICON_GRID=()

# icon_init 是否已完成（幂等标记）。
# _ICON_INITIALIZED 用 ${_ICON_INITIALIZED:-} 检查，不在此预声明。

# ---------------------------------------------------------------------------
# 内置的六个模块图标（12 列 × 12 行）—— 点阵原样照抄 docs/icon-lab.sh，一个点都不改。
# ---------------------------------------------------------------------------
icon_grid() {
  case "$1" in
    assignments) # 作业 DDL：折角文档 + 文本条
      cat <<'EOF'
.########...
.#########..
.##########.
.#........#.
.#.######.#.
.#........#.
.#.######.#.
.#........#.
.#.####...#.
.#........#.
.##########.
.##########.
EOF
      ;;
    schedule) # 课表：台历（两个环 + 实心顶栏 + 2×2 厚日程格）
      cat <<'EOF'
...#....#...
...#....#...
.##########.
.##########.
.#........#.
.#.##..##.#.
.#.##..##.#.
.#........#.
.#.##..##.#.
.#.##..##.#.
.##########.
.##########.
EOF
      ;;
    classrooms) # 空教室：教室轮廓 + 四组空座
      cat <<'EOF'
............
.##########.
.#........#.
.#.##..##.#.
.#.##..##.#.
.#........#.
.#.##..##.#.
.#.##..##.#.
.#........#.
.#........#.
.##########.
............
EOF
      ;;
    grades) # 成绩：三根递增的实心柱 + 基线
      cat <<'EOF'
........##..
........##..
........##..
.....##.##..
.....##.##..
.....##.##..
..##.##.##..
..##.##.##..
..##.##.##..
..##.##.##..
.##########.
.##########.
EOF
      ;;
    exams) # 考试：沙漏（时间在漏）
      cat <<'EOF'
.##########.
..########..
...######...
....####....
.....##.....
.....##.....
.....##.....
....####....
...######...
..########..
.##########.
............
EOF
      ;;
    public) # 公共查询：地球（赤道 + 子午线）
      cat <<'EOF'
....####....
..########..
.##..##..##.
.#...##...#.
#....##....#
############
############
#....##....#
.#...##...#.
.##..##..##.
..########..
....####....
EOF
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

# 键是否在 ICON_KEYS 里。
_icon_is_key() {
  local k
  for k in "${ICON_KEYS[@]}"; do
    [[ "${k}" == "$1" ]] && return 0
  done
  return 1
}

# 把 icon_grid 的输出读进全局 _ICON_GRID（12 行 × 12 列）。
_icon_load_grid() {
  local line
  _ICON_GRID=()
  while IFS= read -r line; do
    _ICON_GRID+=("${line}")
  done < <(icon_grid "$1")
}

# 把前景色 SGR（38;5;N）转成背景色（48;5;N），供 bg 模式铺底。
# 已是背景色则原样返回；不含 38;5;（如真彩色 38;2;…）也原样返回（不报错，仅可能不上色）。
_icon_bg_sgr() {
  local sgr="${1:-}"
  if [[ "${sgr}" == *"48;5;"* ]]; then
    printf '%s' "${sgr}"
  else
    printf '%s' "${sgr/38;5;/48;5;}"
  fi
}

# 生成一行 12 个空格的纯占位（off 模式 / 未知键共用）。
_icon_blank_row() {
  printf '%*s' "${ICON_W}" ''
}

# ---------------------------------------------------------------------------
# 三种渲染器（结果追加到 ICON_ROWS，不写 stdout）
# ---------------------------------------------------------------------------

# half：半块字符 ▀▄█，1 列 × 2 点。颜色作为前景色整行包裹，行尾补复位。
_icon_render_half() {
  local color="${1:-}" r c t b row cells
  for ((r = 0; r < ICON_H; r++)); do
    cells=""
    for ((c = 0; c < ICON_W; c++)); do
      t=0; b=0
      [[ "${_ICON_GRID[r * 2]:c:1}" == '#' ]] && t=1
      [[ "${_ICON_GRID[r * 2 + 1]:c:1}" == '#' ]] && b=1
      if ((t && b)); then cells+='█'
      elif ((t)); then cells+='▀'
      elif ((b)); then cells+='▄'
      else cells+=' '; fi
    done
    if [[ -n "${color}" ]]; then
      row="${color}${cells}${_ICON_RESET}"
    else
      row="${cells}"
    fi
    ICON_ROWS+=("${row}")
  done
}

# bg：背景色空格，1 列 × 1 点；纵向每 2 点取 1 点，行数与 half 完全一致（12 列 × 6 行）。
# 颜色作为背景色逐格铺底（空格是 Narrow 宽度，绝对安全）。无颜色时退化为 '#' 骨架（形状仍可见）。
_icon_render_bg() {
  local color="${1:-}" bg_sgr="" r c row
  if [[ -n "${color}" ]]; then
    bg_sgr="$(_icon_bg_sgr "${color}")"
  fi
  for ((r = 0; r < ICON_H; r++)); do
    row=""
    for ((c = 0; c < ICON_W; c++)); do
      if [[ "${_ICON_GRID[r * 2]:c:1}" == '#' ]]; then
        if [[ -n "${bg_sgr}" ]]; then
          row+="${bg_sgr} ${_ICON_RESET}"
        else
          row+='#'
        fi
      else
        row+=' '
      fi
    done
    ICON_ROWS+=("${row}")
  done
}

# off：六行全是 12 个空格，布局占位与 half/bg 完全一致。
_icon_render_off() {
  local i
  for ((i = 0; i < ICON_H; i++)); do
    ICON_ROWS+=("$(_icon_blank_row)")
  done
}

# ---------------------------------------------------------------------------
# 冻结接口：icon_render
# ---------------------------------------------------------------------------

# icon_render <键> [颜色SGR]
#   键不在 ICON_KEYS 里 → 六行空格，返回非 0。
#   颜色SGR 为调用方传入的完整 SGR 串（如 $'\033[38;5;203m'）；空串 = 不上色。
#   结果写入全局数组 ICON_ROWS（长度恰好 6），不向 stdout 打印任何东西。
icon_render() {
  local key="${1:-}" color="${2:-}" i
  ICON_ROWS=()

  if _icon_is_key "${key}"; then
    _icon_load_grid "${key}"
  else
    _ICON_GRID=()
    for ((i = 0; i < ICON_H; i++)); do
      ICON_ROWS+=("$(_icon_blank_row)")
    done
    return 1
  fi

  case "${ICON_MODE:-off}" in
    half) _icon_render_half "${color}" ;;
    bg)   _icon_render_bg "${color}" ;;
    *)    _icon_render_off ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 冻结接口：icon_plain_row
# ---------------------------------------------------------------------------

# icon_plain_row <下标>
# 给上层（宽度校验）与测试（快照断言）用：返回第 <下标> 行的纯 ASCII 骨架，
# 不含任何 ANSI 转义、不含宽度有歧义的半块字符，长度恒为 12（字节数 = 字符数）。
#   上下两点都实 → '#'
#   只有一点实   → '+'
#   两点都空     → '.'
# ICON_MODE=off 或尚未 icon_render 时返回 12 个空格（off 模式本就不渲染图标）。
icon_plain_row() {
  local idx="${1:-0}" r c t b out=""
  if [[ "${ICON_MODE:-off}" == "off" || ${#_ICON_GRID[@]} -eq 0 ]]; then
    _icon_blank_row
    return 0
  fi
  ((idx < 0)) && idx=0
  ((idx >= ICON_H)) && idx=$((ICON_H - 1))
  r=$((idx * 2))
  for ((c = 0; c < ICON_W; c++)); do
    t=0; b=0
    [[ "${_ICON_GRID[r]:c:1}" == '#' ]] && t=1
    [[ "${_ICON_GRID[r + 1]:c:1}" == '#' ]] && b=1
    if ((t && b)); then out+='#'
    elif ((t || b)); then out+='+'
    else out+='.'; fi
  done
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# 冻结接口：icon_init
# ---------------------------------------------------------------------------

# icon_init —— 幂等。探测终端，确定 ICON_MODE 与 ICON_UNICODE_W。
# 优先级：BUPTY_FORCE_ICONS（half/bg/off）> 非 TTY → off > 实测 DSR 宽度。
#   ICON_UNICODE_W 只在能明确推导时设置：
#     BUPTY_FORCE_ICONS=half → 1；=bg → 2；=off → 不设置
#     实测 W==1 → 1（half）；W==2 → 2（bg）；超时/异常 → 不设置（bg 兜底）
#   上层据此区分「确定是 1 列」与「不知道」，决定制表符边框是否退 ASCII。
icon_init() {
  [[ -n "${_ICON_INITIALIZED:-}" ]] && return 0

  # 默认不声明 ICON_UNICODE_W：只有明确实测/推导时才设置。
  unset ICON_UNICODE_W 2>/dev/null || true

  case "${BUPTY_FORCE_ICONS:-}" in
    half)
      ICON_MODE="half"
      ICON_UNICODE_W=1
      _ICON_INITIALIZED=1
      return 0
      ;;
    bg)
      ICON_MODE="bg"
      ICON_UNICODE_W=2
      _ICON_INITIALIZED=1
      return 0
      ;;
    off)
      ICON_MODE="off"
      _ICON_INITIALIZED=1
      return 0
      ;;
  esac

  # 非 TTY（输出不是终端）：off，不发任何探测转义序列。
  if [[ ! -t 1 ]]; then
    ICON_MODE="off"
    _ICON_INITIALIZED=1
    return 0
  fi

  # stdout 是终端但 stdin 不是：DSR 应答读不到，直接安全兜底 bg（仍可显示颜色）。
  if [[ ! -t 0 ]]; then
    ICON_MODE="bg"
    _ICON_INITIALIZED=1
    return 0
  fi

  # 只探测一次：委托给宽度引擎的 core_probe_ambig（lib/core.sh）。
  # 必须同源——制表符 ─ 和方块 █ 属于同一个 East Asian Ambiguous 宽度类，
  # 各测各的一旦结论不一致，卡片边框和图标就会错位。
  #
  # 关键：BUPTY_AMBIG_W 在 core.sh 加载时就被初始化成 1 或 2，**永远不可能未定义**，
  # 所以不能拿它判断「有没有实测过」。能判断的是 core_probe_ambig 的**返回值**：
  # 实测到才返回 0，超时/无应答/非 TTY 返回 1 且不改动 BUPTY_AMBIG_W。
  # 单独 source 本文件（没有 core.sh）时不要往终端吐 "command not found"，
  # 静默落到下面的 bg 兜底分支即可。
  if declare -F core_probe_ambig >/dev/null 2>&1 \
    && core_probe_ambig "${ICON_DSR_TIMEOUT:-0.15}"; then
    case "${BUPTY_AMBIG_W}" in
      2)
        ICON_MODE="bg"
        ICON_UNICODE_W=2
        ;;
      *)
        # core_probe_ambig 只在实测到 1/2 列时才返回 0，所以走到这里必然是 1 列。
        ICON_MODE="half"
        ICON_UNICODE_W=1
        ;;
    esac
  else
    # 探测失败：保守兜底 bg（仍能显示实心色块，只是 1×1 分辨率）。
    # 刻意不宣称 ICON_UNICODE_W —— 上层据此知道「宽度未知」，保留 Unicode 边框。
    ICON_MODE="bg"
  fi
  _ICON_INITIALIZED=1
}
