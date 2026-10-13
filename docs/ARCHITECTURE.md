# bupty 架构与编码约定

本文档是所有实现 / 测试 / review agent 必须遵守的工程约定。先读本文件与
`docs/protocols.md` 再动手。

## 语言与风格

- 界面文案、注释、提交信息一律中文。
- Shell 脚本用 **bash**（`#!/usr/bin/env bash`），`set -euo pipefail`。
- 变量引用一律 `"${var}"` 双引号；字符串比较用 `[[ ]]`。
- 绝不把密码/token 打印到 stdout/stderr 或写日志。

## 目录职责

```
bin/bupty        入口：解析自身路径 → source lib/*.sh → 进入 tui_main
lib/core.sh      常量/路径/日志/错误/UTF-8/颜色工具，无网络
lib/http.sh      curl 封装（http_get/http_post/http_form），返回状态+body
lib/session.sh   SJD/UCloud 会话缓存（内存变量 + 临时文件），过期自动重登
lib/creds.sh     凭据读写（credentials.json，0700/0600，拒绝符号链接）
lib/parse.sh     纯函数：周次展开、节次/考试时间解析、楼名归一
lib/sjd.sh       教务：登录/课表/空教室/成绩/考试（用 session.sh）
lib/ucloud.sh    教学云：认证链/课程/作业
lib/public.sh    班车/活动/节假日
lib/ui.sh        TUI 原语：清屏/盒子/颜色/列表/输入框/按键读取
lib/icons.sh     首页模块图标：点阵表 + 半块/背景色渲染 + 启动时宽度实测
lib/views/*.sh   各页面：render_<name>() 与 handle_<name>_key()
tui.sh           主事件循环与导航栈
install.sh       安装器
tests/           测试（bash 单测 + python 集成 + 快照）
```

## 函数命名与职责

- 纯解析函数（`lib/parse.sh`）**不得**做网络请求，只吃输入吐结果，方便单测。
- 网络函数命名：`sjd_login` / `sjd_fetch_schedule` / `ucloud_authenticate` /
  `ucloud_fetch_assignments` / `public_fetch_shuttle` 等；内部用 `http.sh` 原语。
- 每个网络函数返回：成功 `return 0` 并把结果写全局变量或 stdout；失败 `return 1` 并
  设置全局 `BUPTY_ERR`（人类可读错误信息）。
- 数据在模块间传递优先用 **JSON 字符串**（`jq` 生成/消费），避免脆弱的分隔符拼接。

## 数据约定

- 课程 / 作业 / 教室等实体统一转成 JSON 行或 JSON 数组，由视图层消费。
- 日期统一 `YYYY-MM-DD`，时刻统一 `HH:MM`。
- 状态码约定：SJD 用 `code==1`，UCloud 用 `code==200`（缺省视为成功）。

## TUI 约定

- 视图 = `render_<name>()`（把界面写到 stdout）+ `handle_<name>_key <key>()`。
- 全局按键：`q` 退出、`Esc`/`Backspace` 返回、`↑/↓` 移动选择、`Enter` 确认、
  `r` 刷新、`Tab`/数字切页。
- 颜色：只用 `lib/ui.sh` 提供的 `ui_color`/主题变量，不硬编码 ANSI 码。
- **选中态的两种角色别混用**：`UI_HL` / `UI_HL_FG` 含**背景色**（`core_sgr` 的第 2 个
  数字参数，呈现在转义里就是 `48;5;N`），只用于「整行/整格铺满」的反显选区（设置页列表、
  各视图选中行、`ui_select_option`）。把它当纯前景色用会在一小段文本上刷出游离色块——
  首页选中卡片就曾这样漏出 9 列蓝底。需要**不带背景**的选中强调前景时用 `UI_SEL`
  （五套主题都定义，纯前景 + 加粗）。每套主题必须完整定义全部 **12** 个角色。
- 渲染后统一 `ui_draw` 一次输出，避免逐行闪烁。

## 宽度、图标与响应式

界面要**严格对齐**，这几条是硬约束：

- **宽度一律以「显示列」为准，绝不能用 `${#s}`。** 在 MSYS2 / Git Bash 上 bash 是
  **面向字节**的（`${#s}` 返回字节数），Linux/WSL 上才是面向字符的。`lib/core.sh`
  加载时用 `_bupty_detect_mb` 探测，把结果放进 `BUPTY_MB`（1=字符模式，0=字节模式），
  两种模式下都要正确。
- **不能拿 UTF-8 字节数当宽度。** 例如 `─`(U+2500) 是 3 字节却只占 1 列。
  必须解出码点再查 East Asian Width 表。
- 统一入口：`core_fit_width <文本>`（打到 stdout）、`_core_width`（无 fork，结果写
  `_CORE_W`）、`core_fit <文本> <宽度>`（截断+补齐）、`core_clip <文本> <宽度>`（只截断，
  不补齐）、`core_pad`。
  热路径用无 fork 的版本——**每个字符 fork 一次 `$(...)` 会让大宽度下的渲染慢到不可用**。
  截断必须整字符裁剪，不能把 UTF-8 序列劈开（`${s%?}` 在字节模式下只砍一个字节）。
  **`core_fit` 会补齐、`core_clip` 不会**：只要求「不许顶破右边界」时用 `core_clip`，
  否则会给本来就不长的行凭空添出尾随空格——字节变了、每帧多传一大截空白，肉眼却看不出来。
  反过来，需要「行宽恰好等于某个值」（对齐、居中、画框）时才用 `core_fit`。
- **East Asian Ambiguous 宽度类是终端相关的**：`▀▄█`(U+2580–259F)、制表符
  (U+2500–257F)、箭头 `↑↓←→`、`①`、`▸▶`、`·` 都在这一类。用全局 `BUPTY_AMBIG_W`（1 或 2）
  表达，启动时由 `core_probe_ambig` 发 DSR(`\033[6n`) 实测。**注意 `BUPTY_AMBIG_W`
  加载时就初始化成 1，永远不会未定义**；要判断「有没有实测过」得看 `core_probe_ambig`
  的返回码（实测到返回 0，失败返回 1 且不改值）。
  - `⚙`(U+2699) **不在**这一类（Unicode 与引擎都判窄，1 列）。
  - 引擎的歧义表是**整块区间**近似（如整个 `2500–257F`、`25A0–25FF`、`2B00–2BFF`、
    `2200–22FF`），比 Unicode 的 A 表粗。已用 `unicodedata.east_asian_width` 逐点核过
    U+00A0–U+2BFF 共 11104 个码点：**引擎从不把「窄」误判成「宽」，也从不漏判「宽」**，
    全部偏差都落在「歧义 vs 窄」这条边界上，只在 `BUPTY_AMBIG_W=2` 的 CJK 终端里
    才显现成 1 列的位移。
  - 两个方向都有偏差，但**界面实际用到的字符里只有 2 个被判错**，已在 `_core_cols_raw`
    开头用「窄例外」特判修掉（`tests/unit_width.sh` 有回归断言）：
    - `›`(U+203A)、`▸`(U+25B8)：Unicode 判**窄**，终端永不加宽；引擎曾按整块判成歧义，
      AMBIG=2 时多算 1 列。`›` 用在 7 个视图的选择行（整行右补空格，表现为高亮底色短 1 列）；
      `▸` 用在首页档位 B 卡片的**框内**（表现为右边框比选中的 `▶` 那一行左移 1 列）。
      现在两者恒判 1 列。**注意这个特判在 `BUPTY_AMBIG_W=1` 下是空操作**，所以它
      不改变 AMBIG=1 终端里的任何渲染结果。
    - 对照：`▶`(U+25B6) 是**真歧义**，不特判，AMBIG=2 时仍按 2 列算。所以选中/未选中
      这对标记的宽度**本来就不同**，布局代码靠补空格补偿，卡片总宽不变——别试图
      「把它们统一成一样宽」，那会反过来破坏对称。
    - 反方向（Unicode 判 A/W 而引擎判窄）共 171 个，集中在希腊字母、西里尔字母、
      上下标数字与 `U+20AC` 等，界面不出现，**未修**。若日后这些字符进入界面
      （例如课程名里出现希腊字母），在 CJK 终端上会有 1 列位移。
- **图标层**（`lib/icons.sh`）：`ICON_KEYS` / `ICON_W=12` / `ICON_H=6` / `ICON_MODE`
  (`half`/`bg`/`off`) / `icon_init` / `icon_render <键> <颜色SGR>`（结果写 `ICON_ROWS`，
  不碰 stdout）/ `icon_plain_row <下标>`（纯 ASCII 骨架，恒 12 字节，供宽度校验）。
  三档 **footprint 必须完全一致**（12 列 × 6 行），上层布局数学才不用分支。
  `icon_init` 内部委托 `core_probe_ambig`，全进程**只探测一次**，保证图标和边框同源。
  测试用 `BUPTY_FORCE_ICONS=half|bg|off` 固定档位。
- **响应式硬不变量：渲染出的任何一行都不得超过 `UI_COLS` 列。** 新增/修改视图时必须
  按宽度分档退化，并在 `UI_ROWS` 不足时降档。`render_<name>` **每次调用都要用最新的
  `UI_COLS`/`UI_ROWS` 重算**，不要在启动时把档位缓存进变量（否则 `WINCH` 重绘后不更新）。
  帧的 chrome 固定 5 行（顶栏 1 + 分隔线 1 + 页脚 3），正文可用行数 = `UI_ROWS - 5`。
  **正文预算要钳到 0**：`UI_ROWS <= 5` 时预算为零或负，此时一行都不该画——为了
  「至少画一行」把可见行数抬到 1，会让 5 行终端渲染出 6 行，把帧顶穿。
  **窄到放不下选中标记时，标记让位。** 选中标记 `▶`(U+25B6) 本身属 Ambiguous 类，
  `BUPTY_AMBIG_W=2` 时它自己就占 2 列；只截断名字而保留标记，整行会恒为 2 列。
  正确姿势是「标记也放不下就丢掉标记」（首页档位 C 与设置页都这么做）。
  **帧高不变量的实测范围。** `UI_ROWS >= 8` 时 8 个页面全部满足「帧高 <= `UI_ROWS`」。
  `UI_ROWS` 为 5/6 时，**首页与设置页以外**的页面会顶穿：它们的占位正文是固定 2 行
  （5 行 chrome + 2 = 7 行），于是 5 行终端超 2 行、6 行终端超 1 行。这是 main 上
  就存在的既有行为（同一份探针在 `main` 与 `ui/home-grid` 上量出的数字逐格一致），
  本分支没有收口它，也没有扩大它；真实的 7 行以下终端跑这套 TUI 本就没有可用性，
  不值得为它改动 7 个页面的空态。首页是唯一做不到「画不出就不画」会被骂的地方，
  已单独处理（`main` 上首页帧高恒为 15 行，现在做到了随 `UI_ROWS` 精确收缩）。
- 边框字符：`┌─│┐` 也是 Ambiguous 类。实测到 `ICON_UNICODE_W=2` 时必须退回 ASCII
  边框（`+ - |`），见 `ui_box_init`。

## 错误处理

- 网络/解析失败：设置 `BUPTY_ERR`，视图显示在状态栏，不崩溃、不清空已有数据。
- 所有 `curl` 调用检查 HTTP 状态码与业务 code；401/失效走 `session.sh` 重登一次。

## 测试约定

- 单测：`tests/unit_*.sh`（bash，用 fixture JSON 断言解析结果），统一由 `tests/run.sh` 跑。
- 联网：`tests/live.sh`（真实网络，只走「读」语义，默认不进 `run.sh`）。
- 快照：`tests/snapshot*.sh`。**不用 `script`/tmux** —— 直接调 `tui_render_once`
  把整帧写进临时文件再断言，因此 `COLUMNS`/`LINES` **不生效**，要指定尺寸必须直接给
  `UI_COLS`/`UI_ROWS` 赋值（并设 `BUPTY_FORCE_ICONS` 固定图标档位）。
  但 `tui_render_once` 内部会调 `ui_size`，而 `ui_size` 从 `stty` 读尺寸**会覆盖你刚赋的值**。
  测试里必须先把函数顶掉：`ui_size() { :; }`，再赋 `UI_COLS`/`UI_ROWS`。
- **量「带颜色的成品行」之前必须先剥 ANSI。** `_core_width` 是「字符串占几列」的纯函数，
  它把 `\033[38;5;244m` 也当可见字符数进去；终端则把转义当零宽。**错误写法会静默骗过测试**：
  ```bash
  # ✗ 千万别这么写：bash 的 glob `*` 贪婪，会一路吞到行尾，
  #   结果是整行被删空、宽度恒为 0，一切断言都「通过」
  printf '%s' "${s//$'\033'\[[0-9;]*[a-zA-Z]/}"
  # ✓ 用最短匹配逐个剥，无 fork
  strip_ansi() {
    local s="$1" out=""
    while [[ "${s}" == *$'\033['* ]]; do
      out+="${s%%$'\033['*}"
      s="${s#*$'\033['}"
      s="${s#*[a-zA-Z]}"
    done
    printf '%s%s' "${out}" "${s}"
  }
  ```
- **`_CORE_W` 是单个全局变量，不是返回值。** 连续两次 `_core_width` 调用之间必须立刻把结果
  取走，否则后一次会覆盖前一次：
  ```bash
  _core_width "${a}"; local aw="${_CORE_W}"    # ✓
  _core_width "${b}"; local bw="${_CORE_W}"
  # ✗ _core_width "${a}"; _core_width "${b}"; x=$((n - _CORE_W - _CORE_W))  ← aw 丢了
  ```
- **宽度引擎对非 ASCII 是 O(n²)**（`${s:i:1}` 在 MSYS2 bash 上偏移越大越慢）。实测：
  40 汉字 ≈ 9ms，400 ≈ 206ms，1600 ≈ 2.2s，3200 ≈ 8.4s。典型 UI 行没问题，但
  **别拿超长中文行或大宽度去穷举扫描**，会假超时。宽度档位要抽样。
- 响应式断言的正确形态是**两条**：① 任何一行 ≤ `UI_COLS`；② 卡片网格内所有行等宽。
  **不要**写「所有行都等宽」—— 页眉/分隔线本来就铺满整行，而卡片网格是居中的固定宽度块，
  两者宽度本来就不该相等，那样写只会刷一屏假报警、把真问题淹掉。
- 凭据从环境变量 `BUPTY_USERNAME`/`BUPTY_PASSWORD` 读取，不写进测试文件。
