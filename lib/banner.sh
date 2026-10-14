#!/usr/bin/env bash
# banner.sh —— 首页顶栏大字符标题块 BUPTY（figlet ANSI Shadow 双线框，47 列 × 6 行）。
#
# 冻结接口（上层照此调用）：
#   BANNER_W=47             # 块的字面列数（每行恰好 47 列；居中位移与门槛都按它算）
#   BANNER_H=6              # 块的行数（固定 6 行）
#   BANNER_ACTIVE           # banner_init 的判定结果：1=显示，0=不显示（顶栏退回 1 行）
#   BANNER_ROWS[0..5]       # banner_render 的产出：恰好 6 行
#   BANNER_CHROME_ROWS      # banner_chrome_rows 的产出：帧的 chrome 行数（5/7 或 11/13）
#   BANNER_TABBAR_ROWS      # banner_chrome_rows 的产出：页签条贡献的行数（2 或 0）
#   BANNER_TABBAR_MIN_BODY  # 页签条的高度门槛：显示页签条后必须给正文留下的行数（12）
#
#   banner_init [无]        # 幂等；按**最新**的 UI_COLS/UI_ROWS 判定，结果写 BANNER_ACTIVE
#   banner_render [颜色SGR] # 六行写进全局数组 BANNER_ROWS[0..BANNER_H-1]
#   banner_plain_row <下标> # 纯 ASCII 画布行（恒 47 字符），给测试与宽度校验用
#   banner_chrome_rows [视图名] # 帧的 chrome 行数（唯一口径），写全局 BANNER_CHROME_ROWS
#                            #   与 BANNER_TABBAR_ROWS（页签条显示与否的**唯一判据**也在它里面）
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

# banner_chrome_rows 的产出：帧的 chrome 行数（5/7 或 11/13）。
BANNER_CHROME_ROWS=5

# banner_chrome_rows 的产出：页签条贡献的行数——显示时 2（页签条 1 行 + 它下面那条分隔线
# 1 行），隐藏时 0。渲染侧只读这个值决定画不画页签条，**不得**另判一套条件。
BANNER_TABBAR_ROWS=0

# 页签条的**高度门槛**：显示页签条之后必须给正文留下的行数（banner_chrome_rows 的高度
# 子句读它，唯一出处就是那里）。取值来自实测——把页签条强制打开后，对「全部视图 ×
# UI_ROWS 8..26 × 宽终端」逐帧量总行数，得到每个视图的「最小可行 body」：
#   public                                       1
#   assignments schedule classrooms grades exams booking   2
#   settings                                    12   ← 决定门槛的就是它
#   （home 另计：本文件不依赖它，且它正被重写，只作参考）
# 取**最大值 12**（宁可保守，见 banner_chrome_rows 里对「为什么是 12」的解释）。
BANNER_TABBAR_MIN_BODY=12

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
#   * UI_ROWS >= 分档门槛 —— 门槛按 UI_COLS 分档（见下表），保证**装饰性的顶栏大字符块
#     永远不会把首页挤低一档**（首页的档位按宽度选版式，顶档 3+3+1 要 16 行 body、
#     中档要 15 行，见 lib/views/home.sh 的档位表；块显示时 chrome 从 5 变 11，正好吃掉
#     6 行，不设这条就会让一次装饰把首页从顶档压到只有列表的最低档）。
#       分档表（UI_ROWS 最小值 = 块显示后的 chrome 11 + 页签条可能占的 2 + 该档位所需 body）：
#         UI_COLS >= 79      → 29 = 11 + 2 + 16（顶档 3+3+1）
#         40 <= UI_COLS < 79 → 28 = 11 + 2 + 15（中档）
#         UI_COLS < 40       → 22（窄档不变；不过 UI_COLS < BANNER_W 时上面那条早已挡掉，
#                                这一档只是 BANNER_W 万一变小时的安全默认值）
#       为什么把页签条的 2 行也算进来：块一显示，首页的 chrome 就比别的页多 6 行。若页签条的
#       高子句（UI_ROWS - chrome - 2 >= BANNER_TABBAR_MIN_BODY）在首页不成立、在别的页成立，
#       同一个尺寸下切页时页签条就会忽隐忽现。29 与 28 都 > 11 + 2 + 12 = 25，所以块一旦显示，
#       页签条的高子句就**必然**已在任何视图（含 base=5 的其它 8 个视图）下满足 ——
#       即 9 个视图的 BANNER_TABBAR_ROWS 在同一 (UI_COLS, UI_ROWS) 下恒等。
#       （唯一的例外是 BUPTY_FORCE_BANNER=1：那是「忽略以上全部门槛」的测试开关，见下。）
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
  # 行数门槛按 UI_COLS 分档（表与理由见函数上方注释）。case/if 赋局部变量，不用 $( )：
  # banner_chrome_rows 每帧都会问到 banner_init，这条在渲染热路径上，必须 fork-free。
  local min_rows=22
  if (( ${UI_COLS:-0} >= 79 )); then
    min_rows=29
  elif (( ${UI_COLS:-0} >= 40 )); then
    min_rows=28
  fi
  (( ${UI_ROWS:-0} >= min_rows )) || return 0

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
# 帧的 chrome 行数（**唯一口径**），结果写全局 BANNER_CHROME_ROWS，同时写
# BANNER_TABBAR_ROWS（页签条贡献的行数：2 或 0）：
#   首页且块显示 = 11 = 状态行 1 + 块 6 + 分隔线 1 + 页脚 3   （+ 页签条 2 = 13）
#   其余一律   = 5  = 顶栏 1 + 分隔线 1 + 页脚 3              （+ 页签条 2 = 7）
# 视图名省略时取当前视图（TUI_VIEW，缺省 home）。正文可用行数一律 = UI_ROWS - 该值，
# tui_render / lib/views/home.sh 都从这里取，不许各自写死（状态行与大块的拆函数见 tui.sh）。
# 刻意不写成「打 stdout 再 $( ) 取」：首页每次按键都会调用它，MSYS2 上一次 $( ) 就是
# 50ms 的 fork（与 _core_width 写 _CORE_W 同一个理由）。
#
# 页签条的显示判据（**全仓库只此一处**；渲染侧只读 BANNER_TABBAR_ROWS 照做，不得另判）：
#   两条是与关系，任一不满足就整条页签条连同它下面那条分隔线一起隐藏
#   （BANNER_TABBAR_ROWS=0，chrome 回到 +0）：
#     ① 宽度子句：把 TUI_TAB_LABELS 按 TUI_TABS 的顺序、以两个空格相接，得到页签串；
#        其**显示宽度**加左右各 1 格留白后必须 ≤ UI_COLS。边界取「等于 UI_COLS 算放得下」。
#        宽度一律用 _core_width 量（结果写 _CORE_W）——签里全是 CJK，字节数 ≠ 显示列。
#     ② 高度子句：显示页签条后**剩下给正文的行数** UI_ROWS - base - 2 必须 ≥
#        BANNER_TABBAR_MIN_BODY。理由：帧高不变量「一帧总行数 ≤ UI_ROWS」在
#        docs/ARCHITECTURE.md 里承诺到 UI_ROWS=8（tests/unit_responsive.sh 的
#        RESP_ROWS_MIN）；顶穿会让终端上滚、把页眉顶出屏幕，所以极矮窗下宁可退化成
#        「没有页签条」，也不能多占这 2 行。
#        门槛值 12 是**实测出来的**（不是凑的）：把页签条强制打开后扫描
#        「全部视图 × UI_ROWS 8..26 × 宽终端」，每个视图的「最小可行 body」为
#        public 1；assignments/schedule/classrooms/grades/exams/booking 2；
#        **settings 12**。取各视图的最大值（宁可保守：门槛必须让**任何**视图都不顶穿，
#        而不是只让当前这一页不顶穿）。settings 之所以要 12，是因为它的 render 自己写死了
#        `body = UI_ROWS - 5`（lib/views/settings.sh，不读 banner_chrome_rows），
#        页签条多占 2 行后它的预算就短 2 行、正好顶穿；页签条一旦显示（本子句保证
#        UI_ROWS - 7 ≥ 12）它的内容又恰好封顶在 12 行，于是不再顶穿。
#        若哪天 settings 改成读 banner_chrome_rows 的 chrome，门槛可降到 2（其余视图的最大值）。
banner_chrome_rows() {
  local view="${1:-${TUI_VIEW:-home}}"
  local base=5 i tw=0
  if [[ "${view}" == "home" ]]; then
    banner_init
    if (( BANNER_ACTIVE )); then
      base=$((BANNER_H + 5))
    fi
  fi
  BANNER_TABBAR_ROWS=0
  # TUI_TABS / TUI_TAB_LABELS 由 tui.sh 定义；单独 source 本文件时可能还没定义，
  # declare -p 是内置命令、零 fork，用它挡掉未定义（而非让 set -u 把调用方炸掉）。
  if declare -p TUI_TABS TUI_TAB_LABELS >/dev/null 2>&1 \
     && (( ${#TUI_TABS[@]} > 0 )) && (( ${#TUI_TAB_LABELS[@]} == ${#TUI_TABS[@]} )); then
    for ((i = 0; i < ${#TUI_TABS[@]}; i++)); do
      _core_width "${TUI_TAB_LABELS[$i]}"
      tw=$((tw + _CORE_W))
      if (( i > 0 )); then tw=$((tw + 2)); fi
    done
    if (( tw + 2 <= ${UI_COLS:-0} )) \
       && (( ${UI_ROWS:-0} - base - 2 >= BANNER_TABBAR_MIN_BODY )); then
      BANNER_TABBAR_ROWS=2
    fi
  fi
  BANNER_CHROME_ROWS=$((base + BANNER_TABBAR_ROWS))
  return 0
}
