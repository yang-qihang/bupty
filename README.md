# bupty

北邮一站式信息查询**终端界面（TUI）**，用 **Bash** 编写。帮助学生在一个软件里查询课表、
作业 DDL、空教室、成绩、考试、班车、节假日与活动等信息。

> 本项目是对 [where_to_study](https://github.com/Nemoyuzx/where_to_study)（GPL-3.0-only）
> 中 CLI 部分的一次 Bash 重写，并把「传大量参数的 CLI」升级为「方向键 / Enter / Backspace
> 的类图形界面」TUI。协议与数据契约迁移自该项目的 Rust 核心，见
> [`docs/protocols.md`](docs/protocols.md)。

## 特性

- **作业 DDL**：聚合教学云全部课程作业，按截止时间升序、标注紧急程度与提交状态。
- **课表**：本周节次网格，今天高亮。
- **空教室**：西土城 / 沙河两校区，按教学楼与节次筛选。
- **成绩 / 考试**：学期成绩、平均绩点与期末考试安排。
- **公共查询**：班车时刻、法定节假日（含离线兜底）、活动 / 竞赛 DDL。
- **记住密码**：凭据安全保存在本地（目录 0700 / 文件 0600），支持教务密码与可选教学云密码。

## 安装

依赖：`bash`（5.0+）、`curl`、`jq`。

```bash
bash install.sh
```

安装到 `~/.local/share/bupty`，入口 `~/.local/bin/bupty`，并自动把 `~/.local/bin` 加入
`bash` / `zsh` / `fish` 的 PATH。重新打开终端后直接运行：

```bash
bupty
```

## 使用

- `↑/↓` 选择，`Enter` 进入，`Esc`/`Backspace` 返回，`q` 退出，`r` 刷新，`Tab` 切换标签页。
- 首次使用请进入「设置」，填写学号与教务密码后登录；凭据会本地保存，下次无需重复输入。

## 测试

```bash
bash tests/run.sh       # 单元测试
bash tests/snapshot.sh  # TUI 渲染快照
bash tests/live.sh      # 真实网络只读集成测试（需凭据）
```

## 许可证

GPL-3.0-only。网络协议与解析逻辑迁移自
[where_to_study](https://github.com/Nemoyuzx/where_to_study)，特此致谢。
