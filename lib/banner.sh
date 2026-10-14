#!/usr/bin/env bash
# banner.sh —— 首页顶栏大字符标题块 BUPTY（figlet ANSI Shadow 双线框，47 列 × 6 行）。
#
# 冻结接口（上层照此调用）：
#   BANNER_W=47             # 块的字面列数（每行恰好 47 列；居中位移与门槛都按它算）
#   BANNER_H=6              # 块的行数（固定 6 行）
#   BANNER_ACTIVE           # banner_init 的判定结果：1=显示，0=不显示（顶栏退回 1 行）
#   BANNER_ROWS[0..5]       # banner_render 的产出：恰好 6 行
#   BANNER_CHROME_ROWS      # banner_chrome_rows 的产出：帧的 chrome 行数（5 或 11）
#
#   banner_init [无]        # 幂等；按**最新**的 UI_COLS/UI_ROWS 判定，结果写 BANNER_ACTIVE
#   banner_render [颜色SGR] # 六行写进全局数组 BANNER_ROWS[0..BANNER_H-1]
#   banner_plain_row <下标> # 纯 ASCII 画布行（恒 47 字符），给测试与宽度校验用
#   banner_chrome_rows [视图名] # 帧的 chrome 行数（唯一口径），写全局 BANNER_CHROME_ROWS
#
# 依赖：读 BUPTY_AMBIG_W（lib/core.sh:162-166 加载时初始化，**恒有定义**）与 core_utf8。
#       颜色一律由调用方传入，本文件不含任何主题色值。
#
# 两个刻意的设计约束（踩过坑，别改）：
#   1. **画布全程纯 ASCII，最后一步才翻译。** 画布记号是 '1'..'7' 与空格（各占 1 字节），
#      直接往字符串里按计算出的偏移插 █（3 字节）会在 C locale（字节模式）下被按字节切开，
#      整块糊掉——本项目已经踩过两次。翻译只把 ASCII 画布逐字符追加成显示字符。
#   2. **判定每次重算，不缓存。** 门槛依赖 UI_COLS/UI_ROWS，而 WINCH 后尺寸会变；
#      banner_init 因此不在首次调用后锁死结果（见 docs/ARCHITECTURE.md 的响应式约定）。

if [[ -n "${_BUPTY_BANNER_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_BANNER_LOADED=1

# ---------------------------------------------------------------------------
# 冻结接口常量
# ---------------------------------------------------------------------------

BANNER_W=47
BANNER_H=6

# banner_init 的判定结果。默认 0：未判定 / 不可显示时都安全（不出块）。
BANNER_ACTIVE=0

# banner_render 的产出：全局数组，长度恰好 6，每行显示列恒为 BANNER_W。
BANNER_ROWS=()

# banner_chrome_rows 的产出：帧的 chrome 行数（5 或 11）。
BANNER_CHROME_ROWS=5

# SGR 复位串（本文件内部使用，不依赖 core.sh）。
_BANNER_RESET=$'\033[0m'

# ---------------------------------------------------------------------------
# 艺术数据：画布记号 1=╗ 2=╔ 3=╝ 4=╚ 5=║ 6=═ 7=█，空格=透明。
# 6 行 × 47 列，逐行等宽（tests 里有逐行断言）。行尾的空格是有意义的列，不要删。
# 常量数组在加载时一次性建好：翻译阶段零 fork、零偏移计算。
# ---------------------------------------------------------------------------
_BANNER_CANVAS=(
  '7777771  771   771 7777771  777777771 771   771'
  '77266771 775   775 77266771 466772663 4771 7723'
  '77777723 775   775 77777723    775     4777723 '
  '77266771 775   775 7726663     775      47723  '
  '77777723 477777723 775         775       775   '
  '4666663   4666663  463         463       463   '
)

# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

# ASCII 画布行 → 显示行，结果写全局 _BANNER_TEXT（不写 stdout，零 fork）。
# 只对 ASCII 画布做 ${s:i:1} 切片：两种多字节模式下 1 字节 = 1 字符 = 1 列，
# 所以这里的下标运算与 locale 无关；Unicode 只作为**追加**出现，不会被切开。
_banner_translate() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "${c}" in
      '1') out+='╗' ;;
      '2') out+='╔' ;;
      '3') out+='╝' ;;
      '4') out+='╚' ;;
      '5') out+='║' ;;
      '6') out+='═' ;;
      '7') out+='█' ;;
      *)   out+="${c}" ;;
    esac
  done
  _BANNER_TEXT="${out}"
  return 0
}

# ---------------------------------------------------------------------------
# 冻结接口：banner_init
# ---------------------------------------------------------------------------

# banner_init —— 幂等（同尺寸同终端下反复调用结果相同，可安全重复调用）。
# 判定本次能否显示大字符块，结果写 BANNER_ACTIVE（1/0）。全部满足才显示：
#   * BUPTY_AMBIG_W == 1 —— █ ═ ║ ╔ ╗ ╚ ╝ 全部落在 lib/core.sh 的 0x2500..0x25FC 快路径，
#     被归为 East Asian Ambiguous。占 2 列时 47 列实占 94 列，居中全错且右侧溢出。
#     先例：ui_box_init（lib/ui.sh）在同样条件下把边框退成 ASCII。
#   * core_utf8 为真 —— 同上，与 ui_box_init 一致（非 UTF-8 终端不吐多字节字符）。
#   * UI_COLS >= BANNER_W —— 放不下就不画。
#   * UI_ROWS >= 22 —— 22 是「首页仍能保住档位 B」的最小行数（body = 22 - 11 = 11，
#     正好是档位 B 阈值）。不加这条，一次装饰就会把首页压到档位 C 的单列列表。
# 强制开关 BUPTY_FORCE_BANNER（照 BUPTY_FORCE_ICONS 的先例）：
#   =1 → 忽略以上全部门槛，强制显示（测试用）；=0 → 强制不显示；未设置 → 按上表判定。
banner_init() {
  BANNER_ACTIVE=0

  case "${BUPTY_FORCE_BANNER:-}" in
    1)
      BANNER_ACTIVE=1
      return 0
      ;;
    0)
      return 0
      ;;
  esac

  # 歧义类实占 2 列（CJK 终端）→ 不出块。BUPTY_AMBIG_W 由 core.sh 初始化，恒有定义。
  (( ${BUPTY_AMBIG_W:-1} == 1 )) || return 0

  # 非 UTF-8 终端不出块。单独 source 本文件（没有 core.sh）时按「不可显示」处理，
  # 不往终端吐 "command not found"。
  if declare -F core_utf8 >/dev/null 2>&1; then
    core_utf8 || return 0
  else
    return 0
  fi

  (( ${UI_COLS:-0} >= BANNER_W )) || return 0
  (( ${UI_ROWS:-0} >= 22 )) || return 0

  BANNER_ACTIVE=1
  return 0
}

# ---------------------------------------------------------------------------
# 冻结接口：banner_render
# ---------------------------------------------------------------------------

# banner_render [颜色SGR]
#   把 6 行写进全局数组 BANNER_ROWS（长度恰好 BANNER_H），不向 stdout 打印任何东西。
#   颜色SGR 为调用方传入的完整 SGR 串（如 "${UI_ACCENT}"）；空串 = 不上色。
#   每行恒为 BANNER_W 个显示列（含行尾空格），调用方按 (UI_COLS - BANNER_W) / 2 居中。
banner_render() {
  local color="${1:-}" row i
  BANNER_ROWS=()
  for ((i = 0; i < BANNER_H; i++)); do
    _banner_translate "${_BANNER_CANVAS[$i]}"
    row="${_BANNER_TEXT}"
    if [[ -n "${color}" ]]; then
      row="${color}${row}${_BANNER_RESET}"
    fi
    BANNER_ROWS+=("${row}")
  done
  return 0
}

# ---------------------------------------------------------------------------
# 冻结接口：banner_plain_row
# ---------------------------------------------------------------------------

# banner_plain_row <下标>
# 给上层（宽度校验）与测试（快照断言）用：返回第 <下标> 行的**纯 ASCII** 画布记号
# （'1'..'7' 与空格），不含任何 ANSI 转义、不含宽度有歧义的字符，长度恒为 BANNER_W
# （字节数 = 字符数 = 显示列数，两种多字节模式下量出来都是 47）。
# 下标超出 0..BANNER_H-1 时钳到边界；与 BANNER_ACTIVE 无关（这是艺术数据的原样，
# 块不显示时它仍然是权威骨架，供测试独立比对）。
banner_plain_row() {
  local idx="${1:-0}"
  (( idx < 0 )) && idx=0
  (( idx >= BANNER_H )) && idx=$((BANNER_H - 1))
  printf '%s' "${_BANNER_CANVAS[$idx]}"
}

# ---------------------------------------------------------------------------
# 冻结接口：banner_chrome_rows
# ---------------------------------------------------------------------------

# banner_chrome_rows [视图名]
# 帧的 chrome 行数（**唯一口径**），结果写全局 BANNER_CHROME_ROWS：
#   首页且块显示 = 11 = 状态行 1 + 块 6 + 分隔线 1 + 页脚 3
#   其余一律   = 5  = 顶栏 1 + 分隔线 1 + 页脚 3
# 视图名省略时取当前视图（TUI_VIEW，缺省 home）。正文可用行数一律 = UI_ROWS - 该值，
# tui_render / tui_render_header / lib/views/home.sh 都从这里取，不许各自写死。
# 刻意不写成「打 stdout 再 $( ) 取」：首页每次按键都会调用它，MSYS2 上一次 $( ) 就是
# 50ms 的 fork（与 _core_width 写 _CORE_W 同一个理由）。
banner_chrome_rows() {
  local view="${1:-${TUI_VIEW:-home}}"
  if [[ "${view}" == "home" ]]; then
    banner_init
    if (( BANNER_ACTIVE )); then
      BANNER_CHROME_ROWS=$((BANNER_H + 5))
      return 0
    fi
  fi
  BANNER_CHROME_ROWS=5
  return 0
}
