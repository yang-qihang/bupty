#!/usr/bin/env bash
# tests/unit_responsive.sh —— 响应式渲染验证（对应 GitHub issue #2）
#
# 目标：**不截图**，直接抽取渲染出来的文本内容，在大量窗口尺寸下验证渲染是否
# 响应式且正确。文件名必须是 unit_*.sh——tests/run.sh 只自动发现 unit_*.sh，
# 叫 snapshot_*.sh 就永远不进 CI。
#
# 四项硬检查（每一页 × 每一档宽度 × 每一档高度 × 每一档图标模式）：
#   1. 溢出：任何一行的显示宽度不得超过 UI_COLS（docs/ARCHITECTURE.md 的硬不变量）
#   2. 对齐：同一帧内连续框线块的所有行必须等宽
#   3. 编码：任何一行都不得含被劈开的 UTF-8（孤立续接字节 / U+FFFD）
#   4. 帧高：一帧的总行数不得超过 UI_ROWS
#
# 两种 bash 多字节语义都要跑（结论应当一致，不一致就是真 bug）：
#   真·字节模式（三个 locale 变量都清空才一定是字节模式，BUPTY_MB=0）：
#     env -u LANG -u LC_ALL -u LC_CTYPE bash tests/unit_responsive.sh
#   字符模式（与用户真实 Git Bash 同档，BUPTY_MB=1）：
#     LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 bash tests/unit_responsive.sh
#   注意 `bash tests/unit_responsive.sh` 本身**不一定**是字节模式：如果环境里
#   有 LC_CTYPE=C.UTF-8 之类的合法多字节 locale，BUPTY_MB 会是 1。必须显式清空。
#
# 性能：MSYS2/Git Bash 上 fork 一次（连 `$( )` 都算）要 50–60ms，而 tui_render
# 一帧大约 12–15 次 fork（顶栏/页脚的 $(ui_paint …)、$(core_fit_width …)）。
# 实测本机 fork 吞吐上限约 70 次/秒，加到 12 个 worker 以上就不再提升——所以
# **总帧数直接决定墙钟时间**，宽度只能抽档不能穷举（13 档 ≈ 59s，256 帧那次 1m55s）。
# 并行：帧列表按序号 % K 切成 K 份交给 K 个 worker 进程跑，父进程汇总
# （RESP_JOBS 可覆盖并行度）。热循环里一律零 fork：
#   * 宽度用 _core_width（结果写全局 _CORE_W），不用 core_fit_width
#   * 剥离转义用参数展开，不用 sed
#   * 一帧只渲染一次，直接分析 tui_render 写出的 TUI_FRAME_FILE
#   * ui_theme_init 只在父进程算一次，worker 从环境继承（省 ~10s 墙钟）
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESP_SELF="${BASH_SOURCE[0]}"

# ---------------------------------------------------------------------------
# 隔离环境：空 XDG_CONFIG_HOME = 没有凭据文件 → 各页一律渲染「未登录」占位，
# 不发任何网络请求，结果确定、可离线复现（同 tests/snapshot.sh 的做法）。
# 全程不读、不打印、不落盘任何凭据。
# ---------------------------------------------------------------------------
if [[ -n "${RESP_BASE:-}" ]]; then
  RESP_TMPDIR="${RESP_BASE}"          # worker 复用父进程的临时目录
else
  RESP_TMPDIR="$(mktemp -d)"
  export RESP_BASE="${RESP_TMPDIR}"
fi
RESP_CFG="${RESP_TMPDIR}/cfg"
mkdir -p "${RESP_CFG}"
export XDG_CONFIG_HOME="${RESP_CFG}"
export BUPTY_CONFIG_DIR="${RESP_CFG}/bupty"

# 载入完整引擎（tui.sh 会打开 set -e，加载完立刻关掉——测试要自己控制失败处理）。
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tui.sh" 2>/dev/null || true
set +e

# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# ---------------------------------------------------------------------------
# 关键一：屏蔽 ui_size
# ---------------------------------------------------------------------------
# tui_render_once / tui_main 都会调 ui_size，而 ui_size 读 `stty size`，会把我们
# 设好的 UI_COLS/UI_ROWS 直接冲掉（COLUMNS/LINES 环境变量它根本不看）。
# 把 ui_size 变成空操作，尺寸才完全由测试指定；父进程会断言这一条确实生效。
ui_size() { :; }

# 关键二：主题/盒子初始化只跑一次。
# `ui_theme_init` 是 11 次 `$(core_sgr …)`，而本机 fork 一次要 ~57ms——实测
# **3.1 秒**。每个 worker 都是一条独立进程，如果各自再算一遍，光这一项就要
# 12 × 3.1s（并行也还是压在 fork 吞吐上限上，实测多花 ~10s 墙钟）。
# 做法：父进程算真的，把结果导出成 BUPTY_TEST_UI_*；worker 不重算，直接从环境
# 取回同名值。worker 渲染出的帧因此与真实渲染**逐字节相同**（含全部转义序列），
# 只是省掉了重复计算——配色不参与任何一条断言，而转义又会被 resp_strip 剥掉。
ui_box_init
ui_box_init() { :; }

RESP_THEME_VARS='ACCENT TEXT MUTED BORDER HL HL_FG SUCCESS WARNING DANGER PURPLE TITLE RESET'

# 父进程：真算一次并导出。
resp_export_theme() {
  local v uv
  for v in ${RESP_THEME_VARS}; do
    uv="UI_${v}"
    printf -v "BUPTY_TEST_UI_${v}" '%s' "${!uv}"
    export "BUPTY_TEST_UI_${v}"
  done
}

# worker：从环境取回，不重算。
resp_import_theme() {
  local v name
  for v in ${RESP_THEME_VARS}; do
    name="BUPTY_TEST_UI_${v}"
    printf -v "UI_${v}" '%s' "${!name:-}"
  done
}

if [[ "${1:-}" == "--worker" ]]; then
  resp_import_theme
else
  ui_theme_init
  resp_export_theme
fi
ui_theme_init() { :; }

# ---------------------------------------------------------------------------
# 文本抽取与度量工具（全部零 fork）
# ---------------------------------------------------------------------------

# 剥离 ANSI 转义，结果写全局 RESP_LINE。
#
# 千万不要用 `${s//$'\033'\[[0-9;]*[a-zA-Z]/}`：bash 的 glob 里 `*` 是「任意字符」
# 通配符而不是正则量词，`[0-9;]*` 的含义是「一个数字/分号，然后任意东西」。
# 于是它从第一个转义一路吃到行尾最后一个字母（彩色行尾必然是 `\033[0m` 的 `m`），
# 整行被删光、宽度量成 0——测试会「全绿」但什么都没验证。实测三种写法：
#   `${s//$'\033'\[[0-9;]*[a-zA-Z]/}`  → 整行变空（错）
#   `sed 's/\033\[[0-9;]*[a-zA-Z]//g'` → 正确，但每行 fork 一次
#   本函数（参数展开循环）            → 正确，且零 fork
# 这里用 `${s#*…}`（最长后缀 = 从**最左**匹配处切开，因为更早的位置必然匹配更长）
# 逐段剥；无终止字母的残尾（截断的转义）直接丢弃，避免死循环。
resp_strip() {
  local s="${1:-}" out="" rest
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"     # 第一个 ESC[ 之前的内容
    s="${s#*$'\033['}"         # 去掉「ESC[」
    rest="${s#*[a-zA-Z]}"      # 去掉参数直到终止字母
    if [[ "${rest}" == "${s}" ]]; then
      s=""                     # 找不到终止字母：截断的转义，整段丢弃
      break
    fi
    s="${rest}"
  done
  RESP_LINE="${out}${s}"
}

# 单元校验：确信 resp_strip 没被写坏（宽度算错的 harness 等于摆设）。
resp_strip_selftest() {
  local s w
  printf -v s '\033[38;5;244m\xE2\x96\xB8\033[0m\033[38;5;252m \xE4\xBD\x9C\xE4\xB8\x9A DDL\033[0m'
  resp_strip "${s}"
  _core_width "${RESP_LINE}"
  w="${_CORE_W}"
  RESP_STRIP_OK=0
  (( w == 10 )) && RESP_STRIP_OK=1
  RESP_STRIP_GOT="${RESP_LINE}|${w}"
}

# UTF-8 结构校验（只判「有没有被劈开」，不判语义）：
#   * 出现 U+FFFD 替换字符 → 非法（说明有东西把坏字节替换掉了）
#   * 字节模式：一条 C locale ERE 完成结构校验——每个字节要么 ASCII，要么是
#     「首字节 + 正确个数的续接字节」。一次正则调用，不逐字节循环。
#     注意：范围起点必须写 \x01 而不是 \x00——`$'…\x00…'` 会在模式里塞进一个 NUL，
#       bash 的 C 字符串在那里被截断，整个正则编译失败（=~ 返回 2），于是所有行
#       都会被误判成「非法」。帧里本来也不可能出现 NUL。
#   * 字符模式：bash 已按字符解码，劈不开，只可能残留 U+FFFD（上面已查）。
resp_valid_utf8() {
  local s="${1:-}" re
  [[ "${s}" == *$'\xEF\xBF\xBD'* ]] && return 1
  if (( BUPTY_MB == 0 )); then
    re=$'^([\x01-\x7f]|[\xc2-\xdf][\x80-\xbf]|[\xe0-\xef][\x80-\xbf][\x80-\xbf]|[\xf0-\xf4][\x80-\xbf][\x80-\xbf][\x80-\xbf])*$'
    [[ "${s}" =~ ${re} ]] || return 1
  fi
  return 0
}

# 框线字符集合：含竖线与各角，**刻意不含横线**（─ / -）。
# 理由：整行横线（顶栏分隔线、页脚边框）不属于任何「块」，算进来只会破坏分组。
# ASCII 回退档下 _UI_BOX_* 是 "+" 与 "|"。
RESP_BOX_GLYPHS=(
  "${_UI_BOX_V}" "${_UI_BOX_TL}" "${_UI_BOX_TR}" "${_UI_BOX_BL}" "${_UI_BOX_BR}"
  "${_UI_BOX_ML}" "${_UI_BOX_MR}" "${_UI_BOX_MT}" "${_UI_BOX_MB}" "${_UI_BOX_MC}"
)

resp_is_box_line() {
  local s="$1" g
  for g in "${RESP_BOX_GLYPHS[@]}"; do
    [[ "${s}" == *"${g}"* ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# 帧分析器
# ---------------------------------------------------------------------------
# resp_analyze <帧文件> <UI_COLS> <UI_ROWS>
# 结果写全局：
#   RESP_LINES     总行数
#   RESP_MAXW      最大行宽
#   RESP_N_OVERFLOW / RESP_N_UTF8 / RESP_N_RAGGED / RESP_N_TALL
#   RESP_FIRST_BAD 第一条问题的可读描述（没有则空）
# 返回 0 = 干净，1 = 有问题。
resp_analyze() {
  local file="$1" cols="$2" rows="$3"
  local raw raw0 line w snip=""
  RESP_LINES=0
  RESP_MAXW=0
  RESP_N_OVERFLOW=0
  RESP_N_UTF8=0
  RESP_N_RAGGED=0
  RESP_N_TALL=0
  RESP_HAS_ESC=0
  RESP_FIRST_BAD=""
  local prev_box=0 prev_w=0

  # read -d '' 把整帧（含行尾换行）读进变量；$(< file) 会吃掉行尾空行，不能用来数帧高。
  IFS= read -r -d '' raw < "${file}" 2>/dev/null || true
  raw="${raw:-}"
  raw0="${raw}"
  # 先整帧剥离转义再切行：渲染尾部那个孤立的 \033[J 会被剥成空串消失，
  # 否则它会被当成额外一行、把帧高算超。
  resp_strip "${raw}"
  raw="${RESP_LINE}"
  # 记下这帧到底有没有转义序列。全部帧都得有——否则说明「剥离 ANSI 再量宽」这条
  # 路径根本没被走到（例如 theme 变量丢了），量出来的宽度也就没有说服力。
  [[ "${raw0}" == *$'\033'* ]] && RESP_HAS_ESC=1

  while IFS= read -r line || [[ -n "${line}" ]]; do
    RESP_LINES=$((RESP_LINES + 1))
    if [[ -z "${line}" ]]; then
      prev_box=0
      continue
    fi
    _core_width "${line}"
    w="${_CORE_W}"
    (( w > RESP_MAXW )) && RESP_MAXW="${w}"

    # --- 1. 溢出 ---------------------------------------------------------
    if (( w > cols )); then
      RESP_N_OVERFLOW=$((RESP_N_OVERFLOW + 1))
      if [[ -z "${RESP_FIRST_BAD}" ]]; then
        snip="$(core_fit "${line}" 46)"
        RESP_FIRST_BAD="溢出：第 ${RESP_LINES} 行宽 ${w} 列 > UI_COLS=${cols} 列｜${snip}"
      fi
    fi

    # --- 3. 编码合法性 ---------------------------------------------------
    if ! resp_valid_utf8 "${line}"; then
      RESP_N_UTF8=$((RESP_N_UTF8 + 1))
      if [[ -z "${RESP_FIRST_BAD}" ]]; then
        snip="$(core_fit "${line}" 46)"
        RESP_FIRST_BAD="UTF-8 被劈开：第 ${RESP_LINES} 行｜${snip}"
      fi
    fi

    # --- 2. 对齐 ---------------------------------------------------------
    # 不变量：把「含框线字符的行」按连续段分组（空行与纯横线行断组），
    # 同一组内所有行的显示宽度必须完全相等。
    # 能排除的：同一个框的内部填充按错误单位（字节数 vs 显示列）计算、或用了
    # 过期的 UI_COLS，导致边框与内部行宽度不一致——即「锯齿框」。
    # 不约束的：框宽不必等于 UI_COLS（窄档本来就允许用更窄的框）；被空行或整行
    # 横线隔开的两个块宽窄可以不同（不算同一个块）。
    if resp_is_box_line "${line}"; then
      if (( prev_box )) && (( w != prev_w )); then
        RESP_N_RAGGED=$((RESP_N_RAGGED + 1))
        if [[ -z "${RESP_FIRST_BAD}" ]]; then
          snip="$(core_fit "${line}" 46)"
          RESP_FIRST_BAD="同一框内宽度不一致：第 ${RESP_LINES} 行宽 ${w} 列 ≠ 上一行 ${prev_w} 列｜${snip}"
        fi
      fi
      prev_box=1
      prev_w="${w}"
    else
      prev_box=0
    fi
  done < <(printf '%s' "${raw}")

  # --- 4. 帧高 -----------------------------------------------------------
  if (( RESP_LINES > rows )); then
    RESP_N_TALL=$((RESP_N_TALL + 1))
    if [[ -z "${RESP_FIRST_BAD}" ]]; then
      RESP_FIRST_BAD="帧高超过 UI_ROWS：${RESP_LINES} 行 > ${rows} 行"
    fi
  fi

  (( RESP_N_OVERFLOW + RESP_N_UTF8 + RESP_N_RAGGED + RESP_N_TALL == 0 ))
}

# 渲染一帧到 TUI_FRAME_FILE（不走 tui_render_once：它每帧还要 mktemp+rm 两次 fork）。
resp_render() {
  local page="$1" cols="$2" rows="$3"
  TUI_VIEW="${page}"
  UI_COLS="${cols}"
  UI_ROWS="${rows}"
  creds_load || true
  tui_render
}

# 切换图标档位。icon_init 带幂等标记 _ICON_INITIALIZED，必须先清掉才能重来。
# 但重算一次要 ~116ms（内部要探一次终端），所以同一个 worker 里档位没变就不重算——
# 主扫描/矮窗扫全是 half，这个缓存把 100 多次 icon_init 压成 1 次。
RESP_CUR_ICON_MODE=""
resp_set_icons() {
  [[ "${1}" == "${RESP_CUR_ICON_MODE}" ]] && return 0
  BUPTY_FORCE_ICONS="$1"
  _ICON_INITIALIZED=""
  icon_init
  RESP_CUR_ICON_MODE="$1"
}

# ---------------------------------------------------------------------------
# worker：只负责把自己那份帧渲染 + 分析，结果写成 TSV
# ---------------------------------------------------------------------------
resp_worker() {
  local jobfile="$1" k="$2" idx="$3" out="$4"
  local ln=0 line tag page cols rows mode ok
  TUI_FRAME_FILE="$(mktemp)"
  : > "${out}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    ln=$((ln + 1))
    (( (ln - 1) % k == idx )) || continue
    read -r tag page cols rows mode <<< "${line}"
    resp_set_icons "${mode}"
    resp_render "${page}" "${cols}" "${rows}" >/dev/null 2>&1
    if resp_analyze "${TUI_FRAME_FILE}" "${cols}" "${rows}"; then ok=1; else ok=0; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${tag}" "${page}" "${cols}" "${rows}" "${mode}" "${ok}" \
      "${RESP_N_OVERFLOW}" "${RESP_N_UTF8}" "${RESP_N_RAGGED}" "${RESP_N_TALL}" \
      "${RESP_HAS_ESC}" "${RESP_FIRST_BAD//$'\t'/ }" >> "${out}"
  done < "${jobfile}"
  rm -f "${TUI_FRAME_FILE}"
  return 0
}

if [[ "${1:-}" == "--worker" ]]; then
  resp_worker "$2" "$3" "$4" "$5"
  exit 0
fi

# ---------------------------------------------------------------------------
# 父进程从这里开始
# ---------------------------------------------------------------------------
TUI_FRAME_FILE="$(mktemp)"
cleanup() { rm -rf "${RESP_TMPDIR}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1) 负向对照：先证明这套检查真的能失败（不能失败的用例毫无价值）
# ---------------------------------------------------------------------------
t_begin "负向对照 · strip 必须正确"
# 带色字符串 `▸ 作业 DDL` 剥离后必须正好 10 列。strip 写错的话下面所有宽度断言
# 都会变成「全 0 通过」，所以这一条放在最前面。
resp_strip_selftest
assert_eq "${RESP_STRIP_OK}" "1" "resp_strip 后 ▸ 作业 DDL 应量出 10 列（实际：${RESP_STRIP_GOT}）"

t_begin "负向对照 · 检查器必须能失败"

# (a) 干净帧 → 0 问题（正向对照：证明它不是「永远报错」）
clean="${RESP_TMPDIR}/clean.txt"
{
  printf '\n'
  printf ' bupty · 首页\n'
  printf '%.0s-' {1..40}
  printf '\n'
  printf ' 内容\n'
} > "${clean}"
resp_analyze "${clean}" 40 24
assert_eq "$((RESP_N_OVERFLOW + RESP_N_UTF8 + RESP_N_RAGGED + RESP_N_TALL))" "0" \
  "干净帧不应报任何问题"

# (b) 某行比 UI_COLS 宽 1 列 → 必须报溢出
over="${RESP_TMPDIR}/over.txt"
printf -v _pad '%*s' 41 ''
printf '%s\n' "${_pad// /x}" > "${over}"
resp_analyze "${over}" 40 24
assert_eq "${RESP_N_OVERFLOW}" "1" "比 UI_COLS 宽 1 列的行必须被报为溢出"

# (c) 被腰斩的 UTF-8（\xE8\xAF 是「课」的前两个字节）→ 必须报编码非法。
#     **这条只在字节模式（BUPTY_MB=0）下有意义**，两种模式要分别断言：
#     字符模式下 bash 自己按 UTF-8 解码，`printf -v s '\xE8\xAF'` 写进变量的其实是
#     U+00E8 U+00AF 两个**合法**字符（字节序 \xC3\xA8\xC2\xAF），压根不是「孤立的
#     续接字节」——不是检查器漏判，而是这种坏串在字符模式里根本构造不出来。
#     因此字符模式下 resp_valid_utf8 只可能靠 U+FFFD 那条（见 d）来判断，
#     而字符模式的宽度引擎走的是按字符截断，物理上也劈不开序列。
printf -v _han '\xE8\xAF\xBE\xE8\xA1\xA8'   # 课表
printf -v _chopped '\xE8\xAF'               # 腰斩的「课」（仅字节模式下是这个含义）
bad="${RESP_TMPDIR}/badutf8.txt"
printf ' %s %s\n' "${_chopped}" "${_han}" > "${bad}"
resp_analyze "${bad}" 80 24
if resp_valid_utf8 "${_chopped}"; then r=0; else r=1; fi
if (( BUPTY_MB == 0 )); then
  assert_eq "${RESP_N_UTF8}" "1" "孤立续接字节必须被判为非法 UTF-8"
  assert_eq "${r}" "1" "resp_valid_utf8 必须否掉腰斩序列"
else
  assert_eq "${RESP_N_UTF8}" "0" "字符模式下 printf 构造不出孤立续接字节（bash 会按 UTF-8 重编码）"
  assert_eq "${r}" "0" "字符模式下 \xE8\xAF 被解成两个合法字符，理应判为合法"
fi
if resp_valid_utf8 "${_han}"; then r=0; else r=1; fi
assert_eq "${r}" "0" "resp_valid_utf8 必须接受完整汉字"

# (d) U+FFFD 替换字符 → 必须报编码非法
printf -v _repl '\xEF\xBF\xBD'
repl="${RESP_TMPDIR}/repl.txt"
printf ' %s\n' "${_repl}" > "${repl}"
resp_analyze "${repl}" 80 24
assert_eq "${RESP_N_UTF8}" "1" "U+FFFD 必须被判为非法"

# (e) 帧多出一行 → 必须报超高
tall="${RESP_TMPDIR}/tall.txt"
printf '%.0s.\n' {1..25} > "${tall}"
resp_analyze "${tall}" 40 24
assert_eq "${RESP_N_TALL}" "1" "25 行的帧在 UI_ROWS=24 下必须报超高"
assert_eq "${RESP_LINES}" "25" "帧高统计必须数出 25 行"

# (f) 同一框内两行宽度不一致 → 必须报锯齿
printf -v _b '%s' "${_UI_BOX_V}"
printf -v _p8 '%*s' 8 ''
printf -v _p9 '%*s' 9 ''
rag="${RESP_TMPDIR}/ragged.txt"
printf '%s%s%s\n' "${_b}" "${_p8}" "${_b}" > "${rag}"
printf '%s%s%s\n' "${_b}" "${_p9}" "${_b}" >> "${rag}"
resp_analyze "${rag}" 40 24
assert_eq "${RESP_N_RAGGED}" "1" "同一框内宽 10 与 11 的两行必须报锯齿"

# (g) 尺寸生效自检：证明 ui_size 屏蔽后 UI_COLS 真的被采纳。
t_begin "ui_size 屏蔽与尺寸生效"
resp_set_icons half
resp_render public 40 24 >/dev/null 2>&1
resp_analyze "${TUI_FRAME_FILE}" 40 24
w40="${RESP_MAXW}"
resp_render public 120 24 >/dev/null 2>&1
resp_analyze "${TUI_FRAME_FILE}" 120 24
w120="${RESP_MAXW}"
assert_eq "${w40}" "40" "UI_COLS=40 时最大行宽应恰为 40 列（说明 ui_size 已被屏蔽且尺寸生效）"
assert_eq "${w120}" "120" "UI_COLS=120 时最大行宽应恰为 120 列"

# (h) 真帧注入：拿一帧真渲染结果，在末行尾部加 2 列 → 必须被抓到。
#     比合成帧更能说明「剥离转义后量宽」确实生效（真帧里全是彩色转义）。
#     页脚最后一行已被 core_fit 补到 UI_COLS-1 列，再加 2 列必然溢出。
#     注意：帧以 `\033[J`（无换行）收尾，直接往尾部拼 XX 会落到转义之后，
#     剥完 ANSI 就变成独立的一行「XX」，一点都溢不出来。所以先剥转义再拼。
inject="${RESP_TMPDIR}/inject.txt"
IFS= read -r -d '' _raw < "${TUI_FRAME_FILE}" 2>/dev/null || true
resp_strip "${_raw:-}"
_plain="${RESP_LINE%$'\n'}"
printf '%sXX\n' "${_plain}" > "${inject}"
resp_analyze "${inject}" 120 24
assert_ok test "${RESP_N_OVERFLOW}" -ge 1

# ---------------------------------------------------------------------------
# 2) 采样矩阵
# ---------------------------------------------------------------------------
# 8 档宽度：极窄（16/20/24，连顶栏都放不下）、home 档位 B/A 的临界（34/40/76/79）、
# 常用 80、超宽 200。30 与 44 被刻意省掉：它们分别夹在 24/34 与 40/76 之间，
# 作为「宽度样本」与相邻档位等价，而下面解释了为什么每一帧都很贵。
#
# 为什么是「抽样」而不是把 16…200 穷举一遍：这一整套的开销几乎全部是 fork
# （每帧 chrome 就要 ~12 次 `$(...)`，每帧约 0.7–0.9s），而本机（MSYS2）实测
# fork 吞吐上限约 70 次/秒（12 个 worker 与 24 个 worker 实测同为 ~70/s，加到
# 12 个以上不再提升）——也就是说 **总帧数直接决定墙钟时间**。
# 256 帧那版跑了 1m55s；99 帧这版 45–55s，覆盖的关键档位一个没少。
# 另外宽度引擎对非 ASCII 是 O(n²)，所以宽度只抽档、不加密。
RESP_WIDTHS=(16 20 24 34 40 76 80 200)
# 矮窗跑更小的样本：矮窗的问题与宽度无关（帧高只取决于 UI_ROWS），
# 两个极端宽度各来一帧足够暴露「没按 UI_ROWS 降档」。
RESP_W_SHORT=(16 200)
# 图标档位：宽度对图标 footprint 没有影响（三档恒 12×6），所以每个非首页只跑
# 一档宽度；而且「全页 × 80 × half」已经被主扫描覆盖了，这里就不重复跑 half。
RESP_W_ICON=(80)
RESP_ICON_MODES=(bg off)
RESP_W_ICON_HOME=(30)
RESP_ROWS_TALL=24
RESP_ROWS_SHORT=12
# 帧高不变量的承诺下界（见 docs/ARCHITECTURE.md「帧高不变量的实测范围」）。
RESP_ROWS_MIN=8
# 并行度：本机 fork 吞吐在 12 个 worker 处到顶（12 与 24 实测都是 ~70 fork/s）。
RESP_JOBS="${RESP_JOBS:-12}"

RESP_JOBFILE="${RESP_TMPDIR}/jobs.tsv"
: > "${RESP_JOBFILE}"
add_job() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "${RESP_JOBFILE}"
}

t_begin "响应式扫描（每帧 4 项检查）"

# 主扫描：全部页 × 全部宽度 × UI_ROWS=24 × 图标 half
for page in "${TUI_TABS[@]}"; do
  for cols in "${RESP_WIDTHS[@]}"; do
    add_job 24 "${page}" "${cols}" "${RESP_ROWS_TALL}" half
  done
done
# 矮窗：全部页 × 样本宽度 × UI_ROWS=12
for page in "${TUI_TABS[@]}"; do
  for cols in "${RESP_W_SHORT[@]}"; do
    add_job 12 "${page}" "${cols}" "${RESP_ROWS_SHORT}" half
  done
done
# 矮窗下界：UI_ROWS=8 是 docs/ARCHITECTURE.md 承诺的帧高不变量下界，要有一档钉住它。
# 再往下（5/6 行）非首页的空态正文是固定 2 行，会顶穿——那是 main 上的既有行为，
# 本分支未收口；把下界定在 8 而不是硬跑到 5，是为了不把既有问题算成这次的回归。
for page in "${TUI_TABS[@]}"; do
  for cols in "${RESP_W_SHORT[@]}"; do
    add_job 8 "${page}" "${cols}" "${RESP_ROWS_MIN}" half
  done
done
# 图标档位：全部页 × bg/off × 常用宽度（half 已由主扫描覆盖）；
# 首页是唯一真正调用 icon_render 的页，再补一个极窄档 × 全档位。
for page in "${TUI_TABS[@]}"; do
  for mode in "${RESP_ICON_MODES[@]}"; do
    for cols in "${RESP_W_ICON[@]}"; do
      add_job icon "${page}" "${cols}" "${RESP_ROWS_TALL}" "${mode}"
    done
  done
done
for mode in half "${RESP_ICON_MODES[@]}"; do
  for cols in "${RESP_W_ICON_HOME[@]}"; do
    add_job icon home "${cols}" "${RESP_ROWS_TALL}" "${mode}"
  done
done

RESP_TOTAL_JOBS="$(wc -l < "${RESP_JOBFILE}" | tr -d '[:space:]')"

# 并行跑（每个 worker 只取序号 % K == idx 的帧）。
for ((wi = 0; wi < RESP_JOBS; wi++)); do
  bash "${RESP_SELF}" --worker "${RESP_JOBFILE}" "${RESP_JOBS}" "${wi}" \
    "${RESP_TMPDIR}/out.${wi}.tsv" >/dev/null 2>&1 &
done
wait

# ---------------------------------------------------------------------------
# 3) 汇总
# ---------------------------------------------------------------------------
RESP_FRAMES=0
RESP_OVERFLOW_TOTAL=0
RESP_UTF8_TOTAL=0
RESP_RAGGED_TOTAL=0
RESP_TALL_TOTAL=0
RESP_NOESC_TOTAL=0
RESP_FAILLINES=()
declare -A RESP_MARK

for ((wi = 0; wi < RESP_JOBS; wi++)); do
  f="${RESP_TMPDIR}/out.${wi}.tsv"
  [[ -f "${f}" ]] || continue
  while IFS=$'\t' read -r tag page cols rows mode ok nover nutf8 nragged ntall hasesc firstbad; do
    [[ -z "${tag}" ]] && continue
    RESP_FRAMES=$((RESP_FRAMES + 1))
    RESP_OVERFLOW_TOTAL=$((RESP_OVERFLOW_TOTAL + nover))
    RESP_UTF8_TOTAL=$((RESP_UTF8_TOTAL + nutf8))
    RESP_RAGGED_TOTAL=$((RESP_RAGGED_TOTAL + nragged))
    RESP_TALL_TOTAL=$((RESP_TALL_TOTAL + ntall))
    [[ "${hasesc}" == "1" ]] || RESP_NOESC_TOTAL=$((RESP_NOESC_TOTAL + 1))
    if [[ "${ok}" == "1" ]]; then
      RESP_MARK["${tag}|${page}|${mode}|${cols}"]="."
    else
      RESP_MARK["${tag}|${page}|${mode}|${cols}"]="X"
      if (( ${#RESP_FAILLINES[@]} < 40 )); then
        RESP_FAILLINES+=("${tag} ${page} ${cols}x${rows} ${mode}: ${firstbad}")
      fi
    fi
  done < "${f}"
done

printf '\n'
printf '=====================================================================\n'
printf '响应式渲染矩阵（. = 通过，X = 发现问题，- = 未采样）\n'
if (( BUPTY_MB )); then mb="字符模式"; else mb="字节模式"; fi
printf '  bash 多字节语义：BUPTY_MB=%s（%s，LANG=%s）\n' "${BUPTY_MB}" "${mb}" "${LANG:-<空>}"
printf '  宽度口径：剥离 ANSI 转义后按显示列计（CJK 2 列，歧义字符按 BUPTY_AMBIG_W=%s）\n' "${BUPTY_AMBIG_W}"
printf '  边框字符：%s（UTF-8 终端用 ┌─│，否则退 ASCII +-|）\n' "${_UI_BOX_TL}${_UI_BOX_H}${_UI_BOX_V}"
printf '  图标档位：half / bg / off（BUPTY_FORCE_ICONS + icon_init）\n'
printf '  离线态：空 XDG_CONFIG_HOME，各页渲染「未登录」占位，无网络请求\n'
printf '=====================================================================\n'

print_row() {  # <tag> <page> <mode> <宽度数组...>
  local tag="$1" page="$2" mode="$3"; shift 3
  local c m i=0
  for c in "$@"; do
    m="${RESP_MARK["${tag}|${page}|${mode}|${c}"]:-_}"
    [[ "${m}" == "_" ]] && m="-"
    printf '%3s' "${m}"
  done
  printf '\n'
}

printf '\n[主扫描] UI_ROWS=%s × 图标 half × 全部 %s 页：\n' "${RESP_ROWS_TALL}" "${#TUI_TABS[@]}"
printf '%-12s' '页'
for c in "${RESP_WIDTHS[@]}"; do printf '%3s' "${c:0:3}"; done
printf '\n'
for page in "${TUI_TABS[@]}"; do
  printf '%-12s' "${page}"
  print_row "24" "${page}" "half" "${RESP_WIDTHS[@]}"
done
printf '（表头为宽度：16/20/24 … 200）\n'
printf '\n[矮窗] UI_ROWS=%s × 图标 half × 样本宽度：\n' "${RESP_ROWS_SHORT}"
printf '%-12s' '页'
for c in "${RESP_W_SHORT[@]}"; do printf '%6s' "${c}"; done
printf '\n'
for page in "${TUI_TABS[@]}"; do
  printf '%-12s' "${page}"
  for c in "${RESP_W_SHORT[@]}"; do
    m="${RESP_MARK["12|${page}|half|${c}"]:-_}"; [[ "${m}" == "_" ]] && m="-"
    printf '%6s' "${m}"
  done
  printf '\n'
done

printf '\n[矮窗下界] UI_ROWS=%s × 图标 half × 样本宽度（帧高不变量的承诺下界）：\n' "${RESP_ROWS_MIN}"
printf '%-12s' '页'
for c in "${RESP_W_SHORT[@]}"; do printf '%6s' "${c}"; done
printf '\n'
for page in "${TUI_TABS[@]}"; do
  printf '%-12s' "${page}"
  for c in "${RESP_W_SHORT[@]}"; do
    m="${RESP_MARK["8|${page}|half|${c}"]:-_}"; [[ "${m}" == "_" ]] && m="-"
    printf '%6s' "${m}"
  done
  printf '\n'
done

printf '\n[图标档位] UI_ROWS=%s × 宽度 %s（首页另加 %s×half/bg/off）；\n' \
  "${RESP_ROWS_TALL}" "${RESP_W_ICON[*]}" "${RESP_W_ICON_HOME[*]}"
printf '%-12s' '页'
for mode in "${RESP_ICON_MODES[@]}"; do
  for c in "${RESP_W_ICON[@]}"; do printf '%11s' "${c}/${mode}"; done
done
printf '\n'
for page in "${TUI_TABS[@]}"; do
  printf '%-12s' "${page}"
  for mode in "${RESP_ICON_MODES[@]}"; do
    for c in "${RESP_W_ICON[@]}"; do
      m="${RESP_MARK["icon|${page}|${mode}|${c}"]:-_}"; [[ "${m}" == "_" ]] && m="-"
      printf '%11s' "${m}"
    done
  done
  printf '\n'
done
printf '%-12s' "home@${RESP_W_ICON_HOME[*]}"
for mode in half "${RESP_ICON_MODES[@]}"; do
  for c in "${RESP_W_ICON_HOME[@]}"; do
    m="${RESP_MARK["icon|home|${mode}|${c}"]:-_}"; [[ "${m}" == "_" ]] && m="-"
    printf '%11s' "${m}"
  done
done
printf '\n'
printf '（half 档在 %s 列下已由主扫描覆盖，此处不重复跑）\n' "${RESP_W_ICON[*]}"

printf '\n=====================================================================\n'
printf '汇总：计划 %s 帧，实际分析 %d 帧\n' "${RESP_TOTAL_JOBS}" "${RESP_FRAMES}"
printf '  溢出（行宽 > UI_COLS）    ：%d 行\n' "${RESP_OVERFLOW_TOTAL}"
printf '  锯齿（同一块内宽不一）    ：%d 处\n' "${RESP_RAGGED_TOTAL}"
printf '  编码（劈开的 UTF-8）      ：%d 行\n' "${RESP_UTF8_TOTAL}"
printf '  帧高（行数 > UI_ROWS）    ：%d 帧\n' "${RESP_TALL_TOTAL}"
printf '  无转义（帧里没有 ANSI）   ：%d 帧（应恒为 0）\n' "${RESP_NOESC_TOTAL}"
printf '=====================================================================\n'

if (( ${#RESP_FAILLINES[@]} > 0 )); then
  printf '\n问题明细（最多 40 条）：\n'
  printf '  %s\n' "${RESP_FAILLINES[@]}"
fi

t_begin "响应式硬不变量"
assert_eq "${RESP_FRAMES}" "${RESP_TOTAL_JOBS}" "所有计划帧都应被渲染并分析（无 worker 丢失）"
assert_eq "${RESP_OVERFLOW_TOTAL}" "0" "所有帧都不得有行超过 UI_COLS"
assert_eq "${RESP_UTF8_TOTAL}" "0" "所有帧都不得含被劈开的 UTF-8"
assert_eq "${RESP_RAGGED_TOTAL}" "0" "同一块内的行必须等宽"
assert_eq "${RESP_TALL_TOTAL}" "0" "任何帧都不得超过 UI_ROWS 行"
assert_eq "${RESP_NOESC_TOTAL}" "0" "每帧都必须含 ANSI 转义（否则「剥转义再量宽」根本没被验证）"

printf '\n复现命令（两种多字节语义都要跑，结果可能不同——不同就是真 bug）：\n'
printf '  # 真·字节模式（三个 locale 变量全清空，BUPTY_MB=0）\n'
printf '  env -u LANG -u LC_ALL -u LC_CTYPE bash tests/unit_responsive.sh\n'
printf '  # 字符模式（与用户真实 Git Bash 同档，BUPTY_MB=1）\n'
printf '  LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 bash tests/unit_responsive.sh\n'

t_summary
