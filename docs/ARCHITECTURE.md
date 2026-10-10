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
- 渲染后统一 `ui_draw` 一次输出，避免逐行闪烁。

## 错误处理

- 网络/解析失败：设置 `BUPTY_ERR`，视图显示在状态栏，不崩溃、不清空已有数据。
- 所有 `curl` 调用检查 HTTP 状态码与业务 code；401/失效走 `session.sh` 重登一次。

## 测试约定

- 单测：`tests/unit_*.sh`（bash，用 fixture JSON 断言解析结果）。
- 集成：`tests/integration.py`（python3 + 仅「读」语义，真实网络）。
- 快照：`tests/snapshot_*.sh`（`script`/tmux 捕获渲染输出断言）。
- 凭据从环境变量 `BUPTY_USERNAME`/`BUPTY_PASSWORD` 读取，不写进测试文件。
