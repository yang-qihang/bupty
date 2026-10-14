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
  （每套具名主题都定义，纯前景 + 加粗）。每套主题必须完整定义全部 **13** 个角色
  （12 个前景角色 + 第 13 个 `UI_BG` 整屏底色）。
- **每套主题自带底色、整屏铺**：`UI_BG` 是本主题的底色 SGR（`core_sgr "" <idx>`，纯
  `48;5;N`）。`UI_RESET` 定义为「重置 + 立刻恢复底色」`$(core_c_reset)${UI_BG}`，随
  `ui_theme_apply` 更新（`UI_BG` 为空时退化成纯 `\033[0m`）——这样几百处 `ui_paint`
  调用点无需逐个改动就都画在主题底色上。`tui_render` 在 `\033[2J` 之前先发 `UI_BG`，
  让擦屏动作本身带底色（依赖 BCE）。退出时 `ui_exit_alt_screen` 在离开备用屏幕前先发一次
  `\033[0m`，避免把底色漏到 shell 提示符上。`ui_paint` 另提供 `bg` 角色供显式铺底。
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
- **大字符标题层**（`lib/banner.sh`）：`BANNER_W=47` / `BANNER_H=6` / `BANNER_ACTIVE` /
  `BANNER_ROWS[0..5]` / `banner_init` / `banner_render <颜色SGR>`（结果写 `BANNER_ROWS`，
  不碰 stdout）/ `banner_plain_row <下标>`（纯 ASCII 骨架，恒 47 字节，供宽度校验）/
  `banner_chrome_rows [视图]`（结果写 `BANNER_CHROME_ROWS`，**帧 chrome 行数的唯一口径**）。
  只在首页顶栏出块（1 行状态行 + 6 行块 + 1 行分隔线），其余 7 页顶栏恒 1 行。
  判定条件：`BUPTY_AMBIG_W == 1`（`█ ═ ║ ╔ ╗ ╚ ╝` 全是 Ambiguous 类，占 2 列时 47 会变 94，
  居中和门槛全错；先例同 `ui_box_init`）、`core_utf8` 为真、`UI_COLS >= 47`、`UI_ROWS >= 22`
  （22 = 首页仍能保住档位 B 的最小行数，`body = 22 - 11 = 11`）。任一条不满足整块不显示，
  顶栏退回今天的样子。测试用 `BUPTY_FORCE_BANNER=1|0` 强制开关。
  画布内部**全程纯 ASCII**（记号 `1`..`7` 与空格），只在最后一步翻译成显示字符——
  直接按偏移往字符串里插 `█`（3 字节）会在 C locale 下被按字节切开（踩过两次）。
- **响应式硬不变量：渲染出的任何一行都不得超过 `UI_COLS` 列。** 新增/修改视图时必须
  按宽度分档退化，并在 `UI_ROWS` 不足时降档。`render_<name>` **每次调用都要用最新的
  `UI_COLS`/`UI_ROWS` 重算**，不要在启动时把档位缓存进变量（否则 `WINCH` 重绘后不更新）。
  帧的 chrome 行数由 `banner_chrome_rows` **唯一给出**，`tui_render` / `tui_render_header` /
  `lib/views/home.sh` 都从这里取，不许各自写死：首页大字符块显示时 **11** 行
  （状态行 1 + 块 6 + 分隔线 1 + 页脚 3），其余一律 **5** 行（顶栏 1 + 分隔线 1 + 页脚 3）。
  **这里说的是「基础 chrome」**：各视图还可能在自己正文里再占页内标题、表头等行
  （如 `lib/views/schedule.sh:360` 的 `-10`、`classrooms.sh:232` 的 `-9`），
  那是**视图局部预算**、不是基础 chrome，两者不要混为一谈。
  正文可用行数 = `UI_ROWS - BANNER_CHROME_ROWS`。
  **正文预算要钳到 0**：预算为零或负时一行都不该画——为了
  「至少画一行」把可见行数抬到 1，会让 5 行终端渲染出 6 行，把帧顶穿。
  **窄到放不下选中标记时，标记让位。** 选中标记 `▶`(U+25B6) 本身属 Ambiguous 类，
  `BUPTY_AMBIG_W=2` 时它自己就占 2 列；只截断名字而保留标记，整行会恒为 2 列。
  正确姿势是「标记也放不下就丢掉标记」（首页档位 C 与设置页都这么做）。
  **帧高不变量的实测范围。** `UI_ROWS >= 8` 时 8 个页面全部满足「帧高 <= `UI_ROWS`」。
  大字符块开启后首页 chrome 涨到 11，但门槛 `UI_ROWS >= 22` 保证了 `UI_ROWS ∈ [22, 28)`
  时首页仍落在档位 B（正文 9 行），帧高 20 ≤ `UI_ROWS`；`UI_ROWS` 22 以下块自动关闭，
  所以这条下界不受影响（实测见 `tests/unit_responsive.sh` 在 `LANG=C.UTF-8` 下的扫描）。
  **降级路径与改动前的关系要精确表述**：除**页脚那一行快捷键提示**外逐字节相同。
  页脚提示串是全部 8 个页面共用的，本分支给它加了 `c 设置`（2026-10-14 由 `, 设置` 改来——
  逗号是标点，中文界面里不好看且易混读；`c` = config，且全 8 页空闲），那是一处**有意的跨全站变更**。
  **这句话的两种口径必须分清，别只报一个数**（初稿只写了后者，已更正）：
  - **原始字节 vs HEAD：56/56 全不同。** 因为配色那一轮引入了 `UI_BG`（每个上色格子都多了
    底色、`UI_RESET` 改成「复位 + 补底色」），每一行的转义字节都变了。**这不算回归。**
  - **归一化掉 `48;5;N` 这一种底色变换后：完全相同 8/56，有差异 48 帧，且 48 处差异
    全部落在页脚提示行（超出页脚行 0 处）。** 8 个相同帧都是 `60×18`——该宽度下
    「按 ` · ` 整段丢弃」后剩下的串恰好等于 HEAD 的串。
  口径与脚本：8 视图 × 7 尺寸（`120×40 100×30 90×28 80×24 70×20 60×18 40×12`），
  `BUPTY_FORCE_BANNER=0` 强制降级、`dark`、未登录、两棵树同环境渲染，
  见 `docs/ui-banner-palette-plan.md` §8 验收标准 3 的复测段。
  归一化**不是**把底色放过：底色画错格子由 `unit_home.sh` 的「帧内只允许本主题 `UI_BG` 索引」
  断言单独管，两条合起来才覆盖完整。
  `tests/unit_banner.sh` 把这条不变量写成了「差异行集合**恰好等于** {页脚行}」——
  不要退化成「整帧允许不同」这种软断言。
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
