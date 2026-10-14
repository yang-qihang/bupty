#!/usr/bin/env bash
# core.sh —— 常量、路径、日志、错误处理、ANSI 颜色基础工具。
# 无网络依赖，被其它所有 lib 文件 source。

set -euo pipefail

# 已 source 保护：同一进程只加载一次。
if [[ -n "${_BUPTY_CORE_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_CORE_LOADED=1

BUPTY_VERSION="0.1.0"
BUPTY_NAME="bupty"

# 全局错误信息（人类可读），供视图状态栏展示。
BUPTY_ERR=""

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

# 安装目录（本仓库根，由 bin/bupty 设置后各文件可引用）。
BUPTY_HOME="${BUPTY_HOME:-}"

# 配置根目录：尊重 XDG_CONFIG_HOME，默认 ~/.config
_bupty_config_root() {
  if [[ -n "${XDG_CONFIG_HOME:-}" && -d "${XDG_CONFIG_HOME}" ]]; then
    printf '%s' "${XDG_CONFIG_HOME}"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.config' "${HOME}"
  else
    printf '%s' "/tmp"
  fi
}

BUPTY_CONFIG_DIR="${BUPTY_CONFIG_DIR:-$(_bupty_config_root)/${BUPTY_NAME}}"
BUPTY_CACHE_DIR="${BUPTY_CONFIG_DIR}/cache"
BUPTY_CREDENTIALS_FILE="${BUPTY_CONFIG_DIR}/credentials.json"
BUPTY_SETTINGS_FILE="${BUPTY_CONFIG_DIR}/settings.json"
BUPTY_FAVORITES_FILE="${BUPTY_CONFIG_DIR}/favorite-events.json"
# 后台通知去重状态：已通知作业 id -> 截止日期（YYYY-MM-DD）。
BUPTY_NOTIFIED_FILE="${BUPTY_CONFIG_DIR}/notified.json"

# 确保配置目录存在（凭据目录 0700）。
core_ensure_dirs() {
  if [[ ! -d "${BUPTY_CONFIG_DIR}" ]]; then
    mkdir -p "${BUPTY_CONFIG_DIR}"
    chmod 700 "${BUPTY_CONFIG_DIR}" 2>/dev/null || true
  fi
  mkdir -p "${BUPTY_CACHE_DIR}"
}

# ---------------------------------------------------------------------------
# 错误 / 日志
# ---------------------------------------------------------------------------

# 设置错误信息（不打印，供 UI 展示）。
core_err() {
  BUPTY_ERR="$*"
}

# 清空错误信息。
core_clear_err() {
  BUPTY_ERR=""
}

# 调试日志（仅 BUPTY_DEBUG=1 时输出到 stderr）。
core_log() {
  if [[ "${BUPTY_DEBUG:-0}" == "1" ]]; then
    printf '[bupty] %s\n' "$*" >&2
  fi
}

# ---------------------------------------------------------------------------
# ANSI 颜色基础
# ---------------------------------------------------------------------------

# 终端是否支持颜色（写入文件/管道时关闭，避免污染快照）。
_bupty_tty() { [[ -t 1 ]]; }

# SGR 序列。用法：core_sgr <fg> [bg|attr...]
# 首参为 256 色前景索引；其余参数中数字为背景索引，关键字为属性（bold/dim/italic/underline）。
core_sgr() {
  local fg="${1:-}"
  shift
  local bg="" arg codes=()
  for arg in "$@"; do
    case "${arg}" in
      bold) codes+=(1) ;;
      dim) codes+=(2) ;;
      italic) codes+=(3) ;;
      underline) codes+=(4) ;;
      [0-9]*) bg="${arg}" ;;
    esac
  done
  [[ -n "${fg}" ]] && codes+=(38 5 "${fg}")
  [[ -n "${bg}" ]] && codes+=(48 5 "${bg}")
  if [[ ${#codes[@]} -eq 0 ]]; then
    printf '\033[0m'
  else
    printf '\033[%sm' "$(printf '%s;' "${codes[@]}" | sed 's/;$//')"
  fi
}

# 便捷常量。
core_c_reset() { printf '\033[0m'; }
core_c_bold() { printf '\033[1m'; }
core_c_dim() { printf '\033[2m'; }

# ---------------------------------------------------------------------------
# 文本工具
# ---------------------------------------------------------------------------

# 去除字符串首尾空白。
core_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# 字符串是否为空（含纯空白）。
core_is_blank() {
  [[ -z "${1:-}" || -z "$(core_trim "${1:-}")" ]]
}

# ---------------------------------------------------------------------------
# 显示宽度引擎（UTF-8 感知，字节模式 / 字符模式双兼容）
# ---------------------------------------------------------------------------
#
# 背景：bash 对字符串的切片语义由当前 locale 决定——
#   * WSL / Linux 常见 UTF-8 locale：bash 按「字符」处理，${#s} 是字符数；
#   * Git Bash / MSYS2 常见 C locale：bash 按「字节」处理，${#s} 是字节数，
#     此时 ${s:i:1} 取到的是「一个字节」，${s%?} 也只砍掉一个字节。
# 老引擎用 `cp > 255 则加 2` 判断，字节模式下每个字节都 < 256，分支永不命中：
# 汉字被算成 3 列、框线/方块被算成 3 列，且截断会把汉字劈成半个。
# 新引擎按码点计算，两种模式下结果一致，且截断绝不劈开 UTF-8 序列。
#
# 全程只用 bash 内建（printf -v / 参数展开 / 算术），零 fork，可在热路径反复调用。

# 多字节模式：1 = bash 按字符处理（WSL/Linux），0 = 按字节处理（Git Bash/MSYS2）。
BUPTY_MB=0

# 探测 bash 是否按字符处理：é（U+00E9）在 UTF-8 下是 2 字节 1 字符，
# 按字符处理时 ${#probe} == 1，按字节处理时 == 2。
_bupty_detect_mb() {
  local probe=$'\xc3\xa9'
  if (( ${#probe} == 1 )); then
    BUPTY_MB=1
  else
    BUPTY_MB=0
  fi
  return 0
}
# 加载时自动探测一次。
_bupty_detect_mb

# Ambiguous（东亚宽度 A）字符实际占几列：只能是 1 或 2，非法值一律回退 1。
# 可用环境变量 BUPTY_AMBIG_W 覆盖；core_probe_ambig 启动时会就地实测更新。
# 只写内存里的这个全局变量，不落盘、不产生任何状态文件。
if [[ "${BUPTY_AMBIG_W:-1}" == "2" ]]; then
  BUPTY_AMBIG_W=2
else
  BUPTY_AMBIG_W=1
fi

# 从字节串 s 的下标 i 处解出一个码点 → _CORE_CP，并写入前进的字节数 _CORE_N。
# 仅字节模式（BUPTY_MB=0）需要。续接字节不合法或越界时退化为「单字节 1 列」，
# 保证 _CORE_N >= 1，调用方按 _CORE_N 前进不会死循环。
_core_utf8_at() {
  local s="$1" i="$2" b0 b1 b2 b3
  _CORE_N=1
  if (( i < 0 || i >= ${#s} )); then
    _CORE_CP=0
    return 0
  fi
  printf -v b0 '%d' "'${s:i:1}"
  if (( b0 < 0x80 )); then
    _CORE_CP=${b0}
  elif (( b0 < 0xE0 )); then
    printf -v b1 '%d' "'${s:i+1:1}"
    if (( (b1 & 0xC0) != 0x80 )); then
      _CORE_CP=${b0}
      return 0
    fi
    _CORE_CP=$(( ((b0 & 0x1F) << 6) | (b1 & 0x3F) ))
    _CORE_N=2
  elif (( b0 < 0xF0 )); then
    printf -v b1 '%d' "'${s:i+1:1}"
    printf -v b2 '%d' "'${s:i+2:1}"
    if (( (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 )); then
      _CORE_CP=${b0}
      return 0
    fi
    _CORE_CP=$(( ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F) ))
    _CORE_N=3
  else
    printf -v b1 '%d' "'${s:i+1:1}"
    printf -v b2 '%d' "'${s:i+2:1}"
    printf -v b3 '%d' "'${s:i+3:1}"
    if (( (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 )); then
      _CORE_CP=${b0}
      return 0
    fi
    _CORE_CP=$(( ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F) ))
    _CORE_N=4
  fi
  return 0
}

# 内部核心：码点 → 列数 _CORE_COLS，同时给出类别 _CORE_CLASS
#   （0 = 零宽，1 = 窄，2 = 宽 W/F，3 = 歧义 A）。
# 热路径每字符调用一次，因此假定 $1 已是合法十进制码点（入口净化在 _core_cols 做）。
# 判定顺序：零宽 > 宽 > 歧义 > 窄。宽优先于歧义，用于消解 231A-231B / 25FD-25FE /
# 1F004 / 1F0CF 这类「Wide 表枚举了、但落在 Ambiguous 区间内」的字符。
#
# 结构：ASCII 快路径 → 高频区块快速通道（O(1) 命中，见下）→ 完整表兜底 → 类别映射列数。
# 完整表很长（逐条比较在 MSYS2 上要几百微秒），界面里 99% 的字符由快速通道直接命中。
_core_cols_raw() {
  local cp="${1:-0}" done=0
  _CORE_CLASS=1
  _CORE_COLS=1
  if (( cp < 0x80 )); then
    return 0
  fi

  # ---- 整块歧义区间里的「窄」例外 ----
  # 下面的快速通道按**整块**归类（见 docs/ARCHITECTURE.md「宽度、图标与响应式」），
  # 会把少数 Unicode 判「窄(N)」的字符一并划进歧义类。终端只加宽 Ambiguous、
  # 不加宽 Narrow，所以这两个字符在任何终端里恒为 1 列，必须特判；否则在 CJK 终端
  # （BUPTY_AMBIG_W=2）上引擎会多算 1 列，而终端只画 1 列，于是整行短 1 列：
  #   › U+203A —— 9 个视图的选择行标记。行模板的预算已按「恒 1 列」定死：
  #               前缀 `" › "` 3 列 + 正文 `UI_COLS - 3` = 恰好 UI_COLS（见
  #               tests/unit_row_width.sh）。此特判在两种 ambig 档下都生效，
  #               所以那批行的宽度与 BUPTY_AMBIG_W 无关
  #   ▸ U+25B8 —— 首页档位 B 卡片的未选中标记（在框内，表现为右边框比选中的
  #               ▶ U+25B6 那一行左移 1 列。▶ 是真正的 Ambiguous，不受此处影响）
  # 注意：在 BUPTY_AMBIG_W=1 下本特判是**空操作**（歧义类也按 1 列算），
  # 因此不会改变现有终端里的任何渲染结果，只是修掉 CJK 终端上的错位。
  if (( cp == 0x203A || cp == 0x25B8 )); then
    return 0 # _CORE_CLASS / _CORE_COLS 已在上方默认成 1（窄）
  fi

  # ---- 快速通道：本 UI 实测会大量出现的区块 ----
  # 取的都是完整表的子区间，且已避开与 Wide 表的重叠（例如 25FD-25FE 是宽，
  # 所以方块/几何通道只到 25FC，剩下的交给完整表）。
  if (( cp >= 0xA1 && cp <= 0xFF )); then
    # Latin-1 补充区：Unicode 里 U+00A1..U+00FF 整段都是 Ambiguous（·、×、é 都在这里）。
    _CORE_CLASS=3
    done=1
  elif (( cp >= 0x4E00 && cp <= 0xA48C )); then
    # CJK 统一表意文字（界面文本的主体）。_core_width 里有一份同样的就地判定。
    _CORE_CLASS=2
    done=1
  elif (( cp >= 0x20000 && cp <= 0x3FFFD )); then
    # CJK 扩展 B 及以后：冷门汉字，界面偶尔会出现。
    _CORE_CLASS=2
    done=1
  elif (( cp >= 0x3000 && cp <= 0x303E )); then
    # 、。「」等 CJK 标点。
    _CORE_CLASS=2
    done=1
  elif (( cp >= 0xFF01 && cp <= 0xFF60 )); then
    # 全角 ASCII：（）：，！？等。
    _CORE_CLASS=2
    done=1
  elif (( cp >= 0x2500 && cp <= 0x25FC )); then
    # 框线 ─│┌┐└┘、方块 █▀▄、几何图形 ●○■□。
    _CORE_CLASS=3
    done=1
  elif (( cp >= 0x2190 && cp <= 0x21FF )); then
    # 方向箭头 ↑↓←→。
    _CORE_CLASS=3
    done=1
  elif (( cp >= 0x2460 && cp <= 0x24FF )); then
    # 带圈数字 ①②③。
    _CORE_CLASS=3
    done=1
  elif (( cp >= 0x2200 && cp <= 0x22FF )); then
    # 数学运算符 ≤ ≥ 等。
    _CORE_CLASS=3
    done=1
  elif (( (cp >= 0x2013 && cp <= 0x2016) ||
          (cp >= 0x2018 && cp <= 0x2019) ||
          (cp >= 0x201C && cp <= 0x201D) ||
          (cp >= 0x2024 && cp <= 0x2027) ||
          cp == 0x203A || cp == 0x203B )); then
    # 常用标点：— – “ ” ‘ ’ … › 及前面高亮用的 ›（U+203A，界面选择行在用）。
    _CORE_CLASS=3
    done=1
  fi

  if (( done == 0 )); then
    _core_classify_slow "${cp}"
  fi

  # 类别 → 列数。歧义字符按 BUPTY_AMBIG_W 取值，非法值就地回退成 1。
  case "${_CORE_CLASS}" in
    0) _CORE_COLS=0 ;;
    2) _CORE_COLS=2 ;;
    3)
      case "${BUPTY_AMBIG_W:-1}" in
        1) _CORE_COLS=1 ;;
        2) _CORE_COLS=2 ;;
        *)
          BUPTY_AMBIG_W=1
          _CORE_COLS=1
          ;;
      esac
      ;;
    *) _CORE_COLS=1 ;;
  esac
  return 0
}

# 完整宽度表（快速通道未命中时才会走到这里）：只写 _CORE_CLASS。
# 判定顺序：零宽 > 宽 > 歧义。
_core_classify_slow() {
  local cp="${1:-0}"
  _CORE_CLASS=1

  # ---- 零宽：组合记号、变体选择符、零宽空格等 ----
  if (( (cp >= 0x0300 && cp <= 0x036F) ||
        (cp >= 0x0483 && cp <= 0x0489) ||
        (cp >= 0x0591 && cp <= 0x05BD) || cp == 0x05BF ||
        (cp >= 0x05C1 && cp <= 0x05C2) ||
        (cp >= 0x05C4 && cp <= 0x05C5) || cp == 0x05C7 ||
        (cp >= 0x0610 && cp <= 0x061A) ||
        (cp >= 0x064B && cp <= 0x065F) || cp == 0x0670 ||
        (cp >= 0x06D6 && cp <= 0x06DC) ||
        (cp >= 0x06DF && cp <= 0x06E4) ||
        (cp >= 0x06E7 && cp <= 0x06E8) ||
        (cp >= 0x06EA && cp <= 0x06ED) || cp == 0x0711 ||
        (cp >= 0x0730 && cp <= 0x074A) ||
        (cp >= 0x07A6 && cp <= 0x07B0) ||
        (cp >= 0x07EB && cp <= 0x07F3) ||
        (cp >= 0x0816 && cp <= 0x0819) ||
        (cp >= 0x081B && cp <= 0x0823) ||
        (cp >= 0x0825 && cp <= 0x0827) ||
        (cp >= 0x0829 && cp <= 0x082D) ||
        (cp >= 0x0859 && cp <= 0x085B) ||
        (cp >= 0x08D3 && cp <= 0x08E1) ||
        (cp >= 0x08E3 && cp <= 0x0902) ||
        cp == 0x093A || cp == 0x093C ||
        (cp >= 0x0941 && cp <= 0x0948) || cp == 0x094D ||
        (cp >= 0x0951 && cp <= 0x0957) ||
        (cp >= 0x0962 && cp <= 0x0963) ||
        cp == 0x0981 || cp == 0x09BC ||
        (cp >= 0x09C1 && cp <= 0x09C4) || cp == 0x09CD ||
        (cp >= 0x09E2 && cp <= 0x09E3) ||
        (cp >= 0x0A01 && cp <= 0x0A02) || cp == 0x0A3C ||
        (cp >= 0x0A41 && cp <= 0x0A42) ||
        (cp >= 0x0A47 && cp <= 0x0A48) ||
        (cp >= 0x0A4B && cp <= 0x0A4D) || cp == 0x0A51 ||
        (cp >= 0x0A70 && cp <= 0x0A71) || cp == 0x0A75 ||
        (cp >= 0x0A81 && cp <= 0x0A82) || cp == 0x0ABC ||
        (cp >= 0x0AC1 && cp <= 0x0AC5) ||
        (cp >= 0x0AC7 && cp <= 0x0AC8) || cp == 0x0ACD ||
        (cp >= 0x0AE2 && cp <= 0x0AE3) ||
        (cp >= 0x1AB0 && cp <= 0x1AFF) ||
        (cp >= 0x1DC0 && cp <= 0x1DFF) ||
        (cp >= 0x200B && cp <= 0x200F) ||
        (cp >= 0x20D0 && cp <= 0x20F0) ||
        (cp >= 0xFE00 && cp <= 0xFE0F) ||
        (cp >= 0xFE20 && cp <= 0xFE2F) || cp == 0xFEFF ||
        (cp >= 0xE0020 && cp <= 0xE007F) ||
        (cp >= 0xE0100 && cp <= 0xE01EF) )); then
    _CORE_CLASS=0
    return 0
  fi

  # ---- 宽 / 全角（East Asian Width = W 或 F） ----
  if (( (cp >= 0x1100 && cp <= 0x115F) ||
        (cp >= 0x231A && cp <= 0x231B) ||
        (cp >= 0x2329 && cp <= 0x232A) ||
        (cp >= 0x23E9 && cp <= 0x23EC) ||
        cp == 0x23F0 || cp == 0x23F3 ||
        (cp >= 0x25FD && cp <= 0x25FE) ||
        (cp >= 0x2614 && cp <= 0x2615) ||
        (cp >= 0x2648 && cp <= 0x2653) ||
        cp == 0x267F || cp == 0x2693 || cp == 0x26A1 ||
        (cp >= 0x26AA && cp <= 0x26AB) ||
        (cp >= 0x26BD && cp <= 0x26BE) ||
        (cp >= 0x26C4 && cp <= 0x26C5) ||
        cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA ||
        (cp >= 0x26F2 && cp <= 0x26F3) ||
        cp == 0x26F5 || cp == 0x26FA || cp == 0x26FD || cp == 0x2705 ||
        (cp >= 0x270A && cp <= 0x270B) ||
        cp == 0x2728 || cp == 0x274C || cp == 0x274E ||
        (cp >= 0x2753 && cp <= 0x2755) || cp == 0x2757 ||
        (cp >= 0x2795 && cp <= 0x2797) ||
        cp == 0x27B0 || cp == 0x27BF ||
        (cp >= 0x2B1B && cp <= 0x2B1C) ||
        cp == 0x2B50 || cp == 0x2B55 ||
        (cp >= 0x2E80 && cp <= 0x2E99) ||
        (cp >= 0x2E9B && cp <= 0x2EF3) ||
        (cp >= 0x2F00 && cp <= 0x2FD5) ||
        (cp >= 0x2FF0 && cp <= 0x2FFB) ||
        (cp >= 0x3000 && cp <= 0x303E) ||
        (cp >= 0x3041 && cp <= 0x3096) ||
        (cp >= 0x3099 && cp <= 0x30FF) ||
        (cp >= 0x3105 && cp <= 0x312F) ||
        (cp >= 0x3131 && cp <= 0x318E) ||
        (cp >= 0x3190 && cp <= 0x31E3) ||
        (cp >= 0x31F0 && cp <= 0x321E) ||
        (cp >= 0x3220 && cp <= 0x3247) ||
        (cp >= 0x3250 && cp <= 0x4DBF) ||
        (cp >= 0x4E00 && cp <= 0xA48C) ||
        (cp >= 0xA490 && cp <= 0xA4C6) ||
        (cp >= 0xA960 && cp <= 0xA97C) ||
        (cp >= 0xAC00 && cp <= 0xD7A3) ||
        (cp >= 0xF900 && cp <= 0xFAFF) ||
        (cp >= 0xFE10 && cp <= 0xFE19) ||
        (cp >= 0xFE30 && cp <= 0xFE52) ||
        (cp >= 0xFE54 && cp <= 0xFE66) ||
        (cp >= 0xFE68 && cp <= 0xFE6B) ||
        (cp >= 0xFF01 && cp <= 0xFF60) ||
        (cp >= 0xFFE0 && cp <= 0xFFE6) ||
        (cp >= 0x16FE0 && cp <= 0x16FE4) ||
        (cp >= 0x17000 && cp <= 0x187F7) ||
        (cp >= 0x18800 && cp <= 0x18CD5) ||
        (cp >= 0x1B000 && cp <= 0x1B152) ||
        (cp >= 0x1B164 && cp <= 0x1B167) ||
        (cp >= 0x1B170 && cp <= 0x1B2FB) ||
        cp == 0x1F004 || cp == 0x1F0CF || cp == 0x1F18E ||
        (cp >= 0x1F191 && cp <= 0x1F19A) ||
        (cp >= 0x1F200 && cp <= 0x1F320) ||
        (cp >= 0x1F32D && cp <= 0x1F335) ||
        (cp >= 0x1F337 && cp <= 0x1F37C) ||
        (cp >= 0x1F37E && cp <= 0x1F393) ||
        (cp >= 0x1F3A0 && cp <= 0x1F3CA) ||
        (cp >= 0x1F3CF && cp <= 0x1F3D3) ||
        (cp >= 0x1F3E0 && cp <= 0x1F3F0) ||
        cp == 0x1F3F4 ||
        (cp >= 0x1F3F8 && cp <= 0x1F43E) ||
        cp == 0x1F440 ||
        (cp >= 0x1F442 && cp <= 0x1F4FC) ||
        (cp >= 0x1F4FF && cp <= 0x1F53D) ||
        (cp >= 0x1F54B && cp <= 0x1F54E) ||
        (cp >= 0x1F550 && cp <= 0x1F567) ||
        cp == 0x1F57A ||
        (cp >= 0x1F595 && cp <= 0x1F596) || cp == 0x1F5A4 ||
        (cp >= 0x1F5FB && cp <= 0x1F64F) ||
        (cp >= 0x1F680 && cp <= 0x1F6C5) || cp == 0x1F6CC ||
        (cp >= 0x1F6D0 && cp <= 0x1F6D2) ||
        (cp >= 0x1F6D5 && cp <= 0x1F6D7) ||
        (cp >= 0x1F6DC && cp <= 0x1F6DF) ||
        (cp >= 0x1F6EB && cp <= 0x1F6EC) ||
        (cp >= 0x1F6F4 && cp <= 0x1F6FC) ||
        (cp >= 0x1F7E0 && cp <= 0x1F7EB) || cp == 0x1F7F0 ||
        (cp >= 0x1F90C && cp <= 0x1F93A) ||
        (cp >= 0x1F93C && cp <= 0x1F945) ||
        (cp >= 0x1F947 && cp <= 0x1F9FF) ||
        (cp >= 0x1FA70 && cp <= 0x1FA7C) ||
        (cp >= 0x1FA80 && cp <= 0x1FA88) ||
        (cp >= 0x1FA90 && cp <= 0x1FABD) ||
        (cp >= 0x1FABF && cp <= 0x1FAC5) ||
        (cp >= 0x1FACE && cp <= 0x1FADB) ||
        (cp >= 0x1FAE0 && cp <= 0x1FAE8) ||
        (cp >= 0x1FAF0 && cp <= 0x1FAF8) ||
        (cp >= 0x20000 && cp <= 0x2FFFD) ||
        (cp >= 0x30000 && cp <= 0x3FFFD) )); then
    _CORE_CLASS=2
    return 0
  fi

  # ---- 歧义（East Asian Width = A）：类别写 3，列数交给调用方的类别映射 ----
  # 界面里真正会用到的都在这张表里：方向箭头 2190-21FF、①②③ 2460-24FF、
  # 框线 2500-257F、方块 ▀▄█ 2580-259F、几何图形 25A0-25FF、杂项符号 2600-26FF。
  # Latin-1 补充区在 Unicode 里整段（U+00A1..U+00FF）都是 Ambiguous，这里合并成一条。
  if (( (cp >= 0x00A1 && cp <= 0x00FF) ||
        cp == 0x0101 || cp == 0x0111 || cp == 0x0113 || cp == 0x011B ||
        (cp >= 0x0126 && cp <= 0x0127) || cp == 0x012B ||
        (cp >= 0x0131 && cp <= 0x0133) || cp == 0x0138 ||
        (cp >= 0x013F && cp <= 0x0142) || cp == 0x0144 ||
        (cp >= 0x0148 && cp <= 0x014B) || cp == 0x014D ||
        (cp >= 0x0152 && cp <= 0x0153) ||
        (cp >= 0x0166 && cp <= 0x0167) || cp == 0x016B ||
        cp == 0x01CE || cp == 0x01D0 || cp == 0x01D2 || cp == 0x01D4 ||
        cp == 0x01D6 || cp == 0x01D8 || cp == 0x01DA || cp == 0x01DC ||
        cp == 0x0251 || cp == 0x0261 ||
        cp == 0x02C4 || cp == 0x02C7 ||
        (cp >= 0x02C9 && cp <= 0x02CB) ||
        cp == 0x02CD || cp == 0x02D0 ||
        (cp >= 0x02D8 && cp <= 0x02DB) ||
        cp == 0x02DD || cp == 0x02DF ||
        cp == 0x2010 ||
        (cp >= 0x2013 && cp <= 0x2016) ||
        (cp >= 0x2018 && cp <= 0x2019) ||
        (cp >= 0x201C && cp <= 0x201D) ||
        (cp >= 0x2020 && cp <= 0x2022) ||
        (cp >= 0x2024 && cp <= 0x2027) ||
        cp == 0x2030 ||
        (cp >= 0x2032 && cp <= 0x2033) ||
        cp == 0x2035 || cp == 0x203A || cp == 0x203B || cp == 0x203E ||
        (cp >= 0x2041 && cp <= 0x2043) ||
        (cp >= 0x2047 && cp <= 0x2051) ||
        (cp >= 0x2190 && cp <= 0x21FF) ||
        (cp >= 0x2200 && cp <= 0x22FF) ||
        (cp >= 0x2300 && cp <= 0x23FF) ||
        (cp >= 0x2460 && cp <= 0x24FF) ||
        (cp >= 0x2500 && cp <= 0x257F) ||
        (cp >= 0x2580 && cp <= 0x259F) ||
        (cp >= 0x25A0 && cp <= 0x25FF) ||
        (cp >= 0x2600 && cp <= 0x2605) ||
        (cp >= 0x2606 && cp <= 0x2609) ||
        (cp >= 0x260A && cp <= 0x260D) ||
        (cp >= 0x2610 && cp <= 0x2613) ||
        (cp >= 0x2616 && cp <= 0x2617) ||
        cp == 0x261C || cp == 0x261E ||
        cp == 0x2640 || cp == 0x2642 ||
        (cp >= 0x2660 && cp <= 0x2661) ||
        (cp >= 0x2663 && cp <= 0x2665) ||
        (cp >= 0x2667 && cp <= 0x266A) ||
        (cp >= 0x266C && cp <= 0x266D) || cp == 0x266F ||
        (cp >= 0x269E && cp <= 0x269F) || cp == 0x26BF ||
        (cp >= 0x26C6 && cp <= 0x26CD) ||
        (cp >= 0x26CF && cp <= 0x26D3) ||
        (cp >= 0x26D5 && cp <= 0x26E1) || cp == 0x26E3 ||
        (cp >= 0x26E8 && cp <= 0x26E9) ||
        (cp >= 0x26EB && cp <= 0x26F1) || cp == 0x26F4 ||
        (cp >= 0x26F6 && cp <= 0x26F9) ||
        (cp >= 0x26FB && cp <= 0x26FC) ||
        (cp >= 0x26FE && cp <= 0x26FF) ||
        cp == 0x273D ||
        (cp >= 0x2B00 && cp <= 0x2B1A) ||
        (cp >= 0x2B1D && cp <= 0x2B4F) ||
        (cp >= 0x2B51 && cp <= 0x2B54) ||
        (cp >= 0x2B56 && cp <= 0x2BFF) ||
        (cp >= 0xE000 && cp <= 0xF8FF) ||
        (cp >= 0x1F000 && cp <= 0x1F02F) ||
        (cp >= 0x1F0A0 && cp <= 0x1F0AE) ||
        (cp >= 0x1F0B1 && cp <= 0x1F0BF) ||
        (cp >= 0x1F0C1 && cp <= 0x1F0CF) ||
        (cp >= 0x1F0D1 && cp <= 0x1F0F5) )); then
    _CORE_CLASS=3
    return 0
  fi

  return 0
}

# 单个码点 → 列数（0/1/2），结果写全局 _CORE_COLS。
# 参数：<码点>，十进制（"9608"）或十六进制（"0x2588"）都接受。
# 入口做一次净化：只有「纯十进制」和「0x + 纯十六进制」才放行。
# 其余值（"abc"、"12abc"）在 set -u 下丢进算术会直接把进程打死——前者报
# unbound variable，后者报 value too great for base——所以一律按 0 处理。
_core_cols() {
  local cp="${1:-0}" hex
  case "${cp}" in
    0[xX]*)
      hex="${cp:2}"
      case "${hex}" in
        "" | *[!0-9a-fA-F]*) cp=0 ;;
      esac
      ;;
    [0-9]*)
      case "${cp}" in
        *[!0-9]*) cp=0 ;;
      esac
      ;;
    *) cp=0 ;;
  esac
  _core_cols_raw "${cp}"
}

# 判定谓词（返回 0/1）。
_core_is_wide() {
  _core_cols "${1:-0}"
  (( _CORE_CLASS == 2 ))
}
_core_is_ambig() {
  _core_cols "${1:-0}"
  (( _CORE_CLASS == 3 ))
}
_core_is_zero() {
  _core_cols "${1:-0}"
  (( _CORE_CLASS == 0 ))
}

# 计算显示宽度，结果写全局 _CORE_W（无 stdout 输出！）。参数：<字符串>
# 热路径：每帧调用几十次。ASCII 走快路径（两种模式下都是 1 字节 1 列、前进 1），
# 其余按码点解码后查表；CJK 汉字在这里就地判掉，不绕 _core_cols_raw。
_core_width() {
  local s="${1:-}" i=0 w=0 b0=0 n
  n=${#s}
  if (( n == 0 )); then
    _CORE_W=0
    return 0
  fi
  for ((i = 0; i < n; i += _CORE_N)); do
    _CORE_N=1
    printf -v b0 '%d' "'${s:i:1}"
    if (( b0 < 0x80 )); then
      w=$((w + 1))
      continue
    fi
    if (( BUPTY_MB )); then
      # 字符模式：bash 已按字符切片，printf 直接给出完整码点。
      _CORE_CP=${b0}
    else
      # 字节模式：手动解 UTF-8，并按 _CORE_N 前进。
      _core_utf8_at "${s}" "${i}"
    fi
    # CJK 统一表意文字是界面文本的主体，就地判掉能省一次函数调用；
    # 区间必须与 _core_cols_raw 的快速通道保持一致（改一处要改两处）。
    if (( _CORE_CP >= 0x4E00 && _CORE_CP <= 0xA48C )); then
      w=$((w + 2))
      continue
    fi
    _core_cols_raw "${_CORE_CP}"
    w=$((w + _CORE_COLS))
  done
  _CORE_W=$w
  return 0
}

# 从尾部安稳地砍掉「一个完整字符」：写入 _CORE_S（剩余串）与 _CORE_CP（被砍掉的码点）。
# 字节模式下必须整段砍掉一个 UTF-8 序列（${s%?} 只砍一个字节，会把汉字劈成半个）。
_core_chop_last() {
  local s="$1" start=0 b=0 n
  n=${#s}
  _CORE_S=""
  _CORE_CP=0
  if (( n == 0 )); then
    return 0
  fi
  if (( BUPTY_MB )); then
    # 字符模式：${s%?} 天然按字符砍，码点直接用 printf 取。
    start=$((n - 1))
    printf -v _CORE_CP '%d' "'${s:start:1}" || _CORE_CP=0
    _CORE_S="${s:0:start}"
    return 0
  fi
  # 字节模式：先跳过尾部的续接字节（10xxxxxx），再砍掉起始字节，一次性砍完整序列。
  while (( n > 0 )); do
    printf -v b '%d' "'${s:n-1:1}"
    n=$((n - 1))
    if (( (b & 0xC0) != 0x80 )); then
      break
    fi
  done
  start=${n}
  _CORE_S="${s:0:start}"
  _core_utf8_at "${s}" "${start}"
  return 0
}

# 补齐显示宽度用的空格。参数：<文本> <目标宽度>
core_pad() {
  local s="${1:-}" width="${2:-0}"
  (( width < 0 )) && width=0
  _core_width "${s}"
  printf '%*s' "$((width > _CORE_W ? width - _CORE_W : 0))" ''
}

# 按显示宽度截断文本并补空格到指定宽度。参数：<文本> <宽度>
# 截断从尾部整字符裁剪（绝不劈开 UTF-8），每砍一个字符就直接扣掉它的列数，
# 不必重算整串宽度；字符串只会变短，因此循环必然终止。
# 结果同时写入全局 _CORE_FIT_OUT（已含补齐空格），供渲染热循环直接用字符串拼接取用；
# core_fit 只负责把它打印出来。
# 取舍：theirs 的 _core_fit_compute 是「无 fork 计算内核」这个接口（热循环要的就是不 fork），
# 但它自带的宽度模型是 cp>255 就按 2 列、循环上界取 ${#s}——和本分支实测 East Asian Width
# 的 _core_width 是两套模型，同一行在两处会被算成不同宽度而对不齐。故保留接口、换内核：
# 两个入口共用 _core_width / _core_chop_last，宽度只此一家。_CORE_FIT_OUT 用 printf -v
# 直接赋值，仍然不 fork（写成 _CORE_FIT_OUT="$(core_fit ...)" 才是又退回 fork）。
_core_fit_compute() {
  local s="${1:-}" width="${2:-0}" pad
  (( width < 0 )) && width=0
  _core_width "${s}"
  while (( _CORE_W > width )); do
    _core_chop_last "${s}"
    s="${_CORE_S}"
    _core_cols_raw "${_CORE_CP}"
    _CORE_W=$((_CORE_W - _CORE_COLS))
  done
  pad=$(( width - _CORE_W ))
  (( pad < 0 )) && pad=0
  printf -v _CORE_FIT_OUT '%s%*s' "${s}" "${pad}" ''
  return 0
}

core_fit() {
  _core_fit_compute "${1:-}" "${2:-0}"
  printf '%s' "${_CORE_FIT_OUT}"
  return 0
}

# 只在**超预算**时才截断，未超预算的串原样返回（一个字节都不动）。
# 与 core_fit 的唯一区别就是「不补空格」：core_fit 恒补齐到目标宽度，套在本来
# 就短的文本上会凭空添出尾随空格——那既改变了输出字节，也让每帧多传一大截空白
# （慢速 SSH 上是实打实的开销），而视图里并没有任何东西依赖这些尾随空格。
# 需要「行宽恰好等于某个值」时用 core_fit；只是「不许顶破右边界」时用这个。
core_clip() {
  local s="${1:-}" width="${2:-0}"
  (( width < 0 )) && width=0
  _core_width "${s}"
  if (( _CORE_W > width )); then
    core_fit "${s}" "${width}"
  else
    printf '%s' "${s}"
  fi
  return 0
}

# 用 DSR（\033[6n）实测 █（U+2588）在终端里占几列，就地更新 BUPTY_AMBIG_W：
#   1. 光标归位清行 → 输出 10 个 █ → 输出 \033[6n 询问光标位置
#   2. 读回 \033[<row>;<col>R，█ 的列数 = (col - 1) / 10
#   3. 清行收尾（调用方应把光标放在一个可以牺牲的行上，例如状态栏）
# 参数：<超时秒数>，默认 0.15。返回 0=测到了，1=没测到。
# 超时 / 无应答 / 解析失败 → 不改动 BUPTY_AMBIG_W（保持原值），返回 1。
# 只写内存全局变量，不写任何状态文件。调用方（tui.sh）负责 raw 模式；
# 本函数不碰 stty，并容忍 echo 开着（解析时只认最后一段数字）。
core_probe_ambig() {
  local timeout="${1:-0.15}"
  # 非 TTY 一律不探测，否则在管道/测试环境里会白等甚至卡住。
  [[ -t 1 && -t 0 ]] || return 1

  local block=$'\xe2\x96\x88'
  local i ch buf="" reply="" col="" cols=0 got=0

  printf '\r\033[K'
  for ((i = 0; i < 10; i++)); do
    printf '%s' "${block}"
  done
  printf '\033[6n'

  # 响应全是 ASCII 字节，字节/字符模式下读法一致。
  # 最多读 64 个字节就要放弃：正常应答是 \033[<row>;<col>R，十几字节就够；
  # 定个上限是为了防止探测期间用户猛敲键盘，让这个循环一直读下去。
  i=0
  while ((i < 64)) && IFS= read -r -s -n1 -t "${timeout}" ch; do
    buf+="${ch}"
    i=$((i + 1))
    if [[ "${ch}" == "R" ]]; then
      got=1
      break
    fi
  done
  printf '\r\033[K'
  (( got )) || return 1

  reply="${buf#*\[}"   # 去掉 \033[ 之前（含回显等杂音）
  reply="${reply%%R*}" # 去掉 R 之后
  col="${reply##*;}"   # 取最后一段作为列号
  if [[ ! "${col}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  cols=$(( (col - 1) / 10 ))
  if (( cols == 1 || cols == 2 )); then
    BUPTY_AMBIG_W=${cols}
    return 0
  fi
  return 1
}

# 判断是否为 UTF-8 终端（决定是否用 Unicode 盒子字符）。
core_utf8() {
  case "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" in
    *UTF-8* | *UTF8* | *utf-8* | *utf8*) return 0 ;;
  esac
  [[ "${BUPTY_FORCE_UTF8:-0}" == "1" ]]
}

# ---------------------------------------------------------------------------
# 时间 / 日期
# ---------------------------------------------------------------------------

# 北京时间今天（YYYY-MM-DD）。依赖系统时区，若不可用用 date -d TZ 兜底。
core_today() {
  TZ=Asia/Shanghai date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d
}

# 北京时间当前 HH:MM。
core_now_hm() {
  TZ=Asia/Shanghai date +%H:%M 2>/dev/null || date +%H:%M
}

# 北京时间当前 RFC3339（秒精度）。
core_now_rfc3339() {
  TZ=Asia/Shanghai date +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%:z
}

# 星期几（1=周一..7=周日）。
core_weekday() {
  local d="${1:-$(core_today)}"
  local w
  w=$(TZ=Asia/Shanghai date -d "${d}" +%u 2>/dev/null || date -d "${d}" +%u)
  printf '%s' "${w}"
}

# 距今天数（正=未来）。日期 a - 日期 b。
core_days_between() {
  local a="${1}" b="${2}"
  local ea eb
  ea=$(date -d "${a}" +%s 2>/dev/null || echo 0)
  eb=$(date -d "${b}" +%s 2>/dev/null || echo 0)
  printf '%s' "$(( (ea - eb) / 86400 ))"
}
