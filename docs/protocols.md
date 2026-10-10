# bupty 网络协议与数据契约（迁移来源）

本文档是从参考项目 [where_to_study](https://github.com/Nemoyuzx/where_to_study)
（GPL-3.0-only）的 Rust 核心源码逐条核对后整理的权威协议说明，是 bupty 各模块实现与
测试的**共享事实源**。实现任何网络功能前先读本文档；如有出入，以学校线上真实响应为准并
更新本文件。

> 约定：所有示例中的 `code:1`（SJD）与 `code:200`（UCloud）表示业务成功。

---

## 0. 通用常量

### 节次时刻（共 14 节，index 0-based）

| 节次(1-based) | 开始 | 结束 |
|---|---|---|
| 1 | 08:00 | 08:45 |
| 2 | 08:50 | 09:35 |
| 3 | 09:50 | 10:35 |
| 4 | 10:40 | 11:25 |
| 5 | 11:30 | 12:15 |
| 6 | 13:00 | 13:45 |
| 7 | 13:50 | 14:35 |
| 8 | 14:45 | 15:30 |
| 9 | 15:40 | 16:25 |
| 10 | 16:35 | 17:20 |
| 11 | 17:25 | 18:10 |
| 12 | 18:30 | 19:15 |
| 13 | 19:20 | 20:05 |
| 14 | 20:10 | 20:55 |

### 校区

| id | 名称 |
|---|---|
| `01` | 西土城 |
| `04` | 沙河 |

`normalize_campus_id`：纯数字时左补零到 2 位；空则默认 `01`。

### 学期号推断 `suggested_term_for_date`

- 月份 2..=7 → 春季：`<year-1>-<year>-2`，锚点当年 `03-02`。
- 其他 → 秋季：`<year>-<year+1>-1`，锚点当年 `09-01`（1 月算上一年）。
- 第一周周一 = 锚点所在周的周一。

学期号格式校验 `is_valid_term_id`：`YYYY-YYYY-1|2`（共 11 字符）。

---

## 1. 教务 SJD（`jwglweixin.bupt.edu.cn`）

Origin：`https://jwglweixin.bupt.edu.cn`（下称 `SJD_ORIGIN`）。

### 1.1 登录

```
POST https://jwglweixin.bupt.edu.cn/bjyddx/login
Content-Type: application/x-www-form-urlencoded
Origin: https://jwglweixin.bupt.edu.cn
Referer: https://jwglweixin.bupt.edu.cn/sjd/#/login
User-Agent: Mozilla/5.0
Body(form): userNo=<学号>  pwd=<教务密码>
```

成功响应（`code == 1`，可能是数字或字符串 `"1"`）：

```json
{ "code": 1, "Msg": "success", "data": { "token": "……", "expires_in": 7200 } }
```

`token` 为空 → 报错。`expires_in` 可能缺失（默认按 20 分钟）。token 仅存内存，不落盘。

登录失败（`code != 1`）：取 `Msg`/`msg` 字段作为错误信息，视为 401 失效。

### 1.2 后续请求头（除登录外一律带上）

```
token: <token>
Origin: https://jwglweixin.bupt.edu.cn
Referer: https://jwglweixin.bupt.edu.cn/sjd/#/restClassroom
User-Agent: Mozilla/5.0
```

### 1.3 失效判定

- HTTP `401` → 失效。
- HTTP 200 或 500 但 body 里 `code == 401`（数字或字符串）→ 失效（SJD 特有）。
- 其他 4xx/5xx → 普通错误，不重登。

### 1.4 课表 `student/curriculum`

```
POST https://jwglweixin.bupt.edu.cn/bjyddx/student/curriculum?week=          # 当前周
POST https://jwglweixin.bupt.edu.cn/bjyddx/student/curriculum?week=all       # 全学期
```

响应（`code == 1`）：

```json
{ "code": 1, "data": [
  {
    "week": "1",
    "semesterId": "2025-2026-2",
    "xnxq01id": "2025-2026-2",
    "item": [ [ [ {课程对象} ... ] ] ],
    "date": [ { "mxrq": "2026-03-02", "xqid": "1", "zc": "1" } ],
    "topInfo": [ { "week": "1", "semesterId": "…", "xnxq01id": "…" } ]
  }
] }
```

课程对象字段（在 `item` 任意深度的数组/对象里，含 `courseName` 或 `jx0408id` 即视为课程）：

| 字段 | 含义 | 备注 |
|---|---|---|
| `courseName` | 课程名 | 空则「未命名课程」 |
| `teacherName` | 教师 | |
| `buildingName` | 楼 | |
| `classroomName` / `location` | 教室 | 见 `normalize_course_room` |
| `classWeek` / `classWeekDetails` | 周次文本 | 见周次展开 |
| `classTime` | 节次编码 | 首字符跳过，之后每 2 位=节次节点(1-based) |
| `weekDay` | 星期(1=周一..7) | |
| `startTime` / `endTIme`(或 `endTime`) | 起止时刻 | 空则用节次时刻表 |
| `jx0408id` | 源课程 ID | |

**周次展开规则**（`expand_week_numbers`）：
- 输入如 `1-18`、`2-18双`、`1,3,5`、`第1周,第3周`、`1-17单,2-18双`。
- 处理顺序：中文逗号 `，`→`,`，去空格，记录全局 `单`/`双`，去 `周`，去 `[...]` 与 `(...)`。
- 按 `,` 切分，每项：`a-b` 展开区间；单数解析为单周。项内 `单`→保留奇数、`双`→保留偶数；项内无标记且全局有 `单/双` 时按全局奇偶。
- 结果去重、升序。

**节次解析规则**（`parse_sjd_slots`）：
- `classTime` 去首字符后，用 `\d{2}` 提取所有 2 位数字为节次节点(1-based)。
- 若无，则回退从 `weekNoteDetail` 提取数字。
- `start_slot = min(节点)-1`，`end_slot = max(节点)-1`（0-based），越界或 start>end 则丢弃该课程。

**教室归一**（`normalize_course_room`）：全角横线 `－—–` → `-`；`<单个数字>-<3位数字>` 时去掉楼号前缀只留房间号（如 `3-335`→`335`、`教1-101`→`101`，但 `202-203` 保留）。

**当前周 / 学期推断**（`infer_term_start_date` / `infer_term_id`）：
- 学期号：依次取 `data[0].semesterId`、`data[0].xnxq01id`、`topInfo[0].semesterId`、`topInfo[0].xnxq01id`，首个非空。
- 开学第一周周一：在 `date[]` 中找首个 `mxrq` 非空且 `zc != "all"` 的项，取其 `zc`（周次，负值丢弃）与 `mxrq`（某日期）与 `xqid`（星期，`0`→周日，`1..7`）；周次缺失时回退 `data[0].week` / `topInfo[0].week`。计算：该日期所在周的周一 = `mxrq - (weekday-1) 天`；开学周一 = 周一 - `(zc-1) 周`。

### 1.5 空教室 `todayClassrooms`

```
GET https://jwglweixin.bupt.edu.cn/bjyddx/todayClassrooms?campusId=01   # 或 04
```

响应（`code == 1`）：

```json
{ "code": 1, "Msg": "success", "data": [
  { "NODENAME": "1",  "CLASSROOMS": "校本部-教一楼-1-101(80),未来学习大楼-202-203(60)" },
  { "NODENAME": "第10节", "CLASSROOMS": "未来学习大楼-105(36)" }
] }
```

- `NODENAME` 取首个数字为节次(1..14，0-based)；越界或非数字跳过。
- `CLASSROOMS` 逗号分隔，每项 `楼-房间(容量)`。`parse_classroom`：先剥掉 `(容量)` 记 size；`-` 切分；若前缀为 `校本部/西土城/沙河` 且 ≥3 段，building 取前两段、room 取第三段起。
- 楼名归一 `normalize_building_name`（去 `校本部-/西土城-/沙河-` 前缀、去空格），映射表：
  - `1/教一楼`→`教1`，`2/教二楼`→`教2`，`3/教三楼`→`教3`，`4/教四楼`→`教4`
  - `未来学习大楼`→`主楼`
  - `N/N楼/N座/北楼/综合教学楼N/综合楼N/综合N`→`综合教学楼N`；`S`…→`综合教学楼S`
  - `教学实验综合楼N(各种变体)/综教N(各种变体)`→`教学实验综合楼N`；`S`…→`教学实验综合楼S`
  - `智慧楼/智慧教室楼/智慧教室`→`智慧教学楼`
- 只保留 `original_building_name` 白名单楼名：`教1/教2/教3/教4/主楼/综合教学楼N/综合教学楼S/教学实验综合楼N/教学实验综合楼S/智慧教学楼`。
- `教学实验综合楼` 需按房间号首字符 `N/n/北`→N 楼、`S/s/南`→S 楼。
- 房间号取 `\d{3}(-\d{3})?` 首个匹配；同楼同房间聚合各节次。
- 结果按 `(building, room)` 排序。空教室接口仅支持当天查询。

### 1.6 成绩与学期

```
POST https://jwglweixin.bupt.edu.cn/bjyddx/currentTerm                          # 当前学期
POST https://jwglweixin.bupt.edu.cn/bjyddx/semesterList                          # 学期列表
POST https://jwglweixin.bupt.edu.cn/bjyddx/student/termGPA?semester=<term>&type=<t>
POST https://jwglweixin.bupt.edu.cn/bjyddx/student/examinationArrangement?semester=<term>
```

（均为 POST，带 1.2 的请求头。）

- `currentTerm` → `{ "code":1, "data":[{ "semesterId":"2026-2027-1" }] }`
- `semesterList` → `{ "code":1, "data":[{ "semesterId":"…", "semesterName":"…" }] }`（去重；name 空则用 id）
- `termGPA` 参数 `type`：`1`=最好(默认)、`0`=首次、`""`=全部。响应：
  ```json
  { "code":1, "data":[ { "pjxfjd":"3.50", "achievement":[
      { "courseName":"…", "fraction":"95", "credit":"4", "kcbh":"…",
        "curriculumAttributes":"…", "courseNature":"…", "examinationNature":"…",
        "curSemesterName":"…", "cjbs":"…", "cj0708id":"…" } ] } ] }
  ```
  注意 `fraction`/`credit` 可能是数字 0 或字符串（`"合格"`、`"0"`），保留原值；`pjxfjd` 仅学校返回时展示。
- `examinationArrangement` → `{ "code":1, "data":[ { "courseName":"…", "examinationPlace":"…", "time":"2026-09-07 09:20-11:00" } ] }`
  考试时间 `time` 需正则解析：严格匹配一个日期 + 两个时刻 `HH:MM`，中间分隔符为 `- – — ~ ～ 至 到` 或空白；`另行通知` 则日期/时刻留空；备选字段 `ksqssj`(日期) + `zssj1`(起) + `zssj2`(止)。start<end 且 start<24:00。

---

## 2. 教学云 UCloud（作业 / 课程）

认证链四步，全部走 HTTPS，禁止重定向跟随（`curl` 默认不跟随即可，手动读取 `Location`）。

### 2.1 统一认证登录页

```
GET https://auth.bupt.edu.cn/authserver/login?service=https%3A%2F%2Fucloud.bupt.edu.cn
User-Agent: <UA>
```

- 保存响应 `Set-Cookie`（多个以 `; ` 连接）。
- 从 HTML 中解析 `<input name="execution" value="…">` 的 value（属性顺序任意、需 HTML 实体解码 `&amp;`→`&` 等）。

### 2.2 提交登录

```
POST https://auth.bupt.edu.cn/authserver/login?service=https%3A%2F%2Fucloud.bupt.edu.cn
Content-Type: application/x-www-form-urlencoded
Cookie: <2.1 的 cookie>
Referer: <2.1 的 URL>
User-Agent: <UA>
Body(form): username=<学号> password=<教学云密码> type=username_password execution=<execution> _eventId=submit
```

- 读响应 `Location` 头，形如 `https://ucloud.bupt.edu.cn/?ticket=ST-xxxx`。
- 校验 host 必须是 `ucloud.bupt.edu.cn` 且 https；取 `ticket` query 参数，空 → 401（提示检查账号密码/验证码）。

### 2.3 换取 access_token

```
POST https://apiucloud.bupt.edu.cn/ykt-basics/oauth/token
Content-Type: application/x-www-form-urlencoded
Authorization: Basic cG9udGFsOnBvcnRhbF9zZWNyZXQ=
Tenant-Id: 000000
Accept: application/json, text/plain, */*
Referer: https://ucloud.bupt.edu.cn/
User-Agent: <UA>
Body(form): ticket=<ticket> grant_type=third
```

响应：`{ "access_token":"…", "userId":"…", "expires_in":7200 }`（`userId` 可能叫 `user_id`）。
`Authorization` 值为官方公开 OAuth client（解码 `portal:portal_secret`），非用户凭据。

### 2.4 API 请求头（后续统一）

```
Authorization: Basic cG9udGFsOnBvcnRhbF9zZWNyZXQ=
Tenant-Id: 000000
Accept: application/json, text/plain, */*
Referer: https://ucloud.bupt.edu.cn/
User-Agent: <UA>
Blade-Auth: <access_token>
```

API 业务成功：`code` 缺失视为成功；否则 `code == 200`（数字或字符串 `"200"`）。
失效判定：`code==401` 或 msg 含 `token expired / invalid token / token失效 / token过期 / 登录已过期 / 登录超时 / 请先登录 / 未登录 / 登录失效`（大小写不敏感）。

### 2.5 课程列表

```
GET https://apiucloud.bupt.edu.cn/ykt-site/site/list/student/current?size=9999&current=1&userId=<id>&siteRoleCode=2
```

响应 `data.records[]` 每项：`id`/`siteId`/`courseId`（课程 ID）、`siteName`/`courseName`/`siteTitle`/`name`（课程名）、`teachers[]`（每项 `.name`）。

### 2.6 每门课作业列表

```
POST https://apiucloud.bupt.edu.cn/ykt-site/work/student/list
Content-Type: application/json
Body: { "siteId":"<课程id>", "userId":"<id>", "keyword":"", "chapterId":"", "nodeId":"",
        "current":1, "size":9999, "studentAssignmentStatus":"", "status":"",
        "sortColumn":"", "sortType":"" }
```

响应 `data.records[]` 每项：

| 字段 | 含义 |
|---|---|
| `id` / `assignmentId` / `activityId` | 作业 ID |
| `assignmentTitle` / `activityName` / `title` | 标题 |
| `siteName` / `courseName` / `siteTitle` | 课程名（可被 course 覆盖） |
| `siteId` / `courseId` | 课程 ID |
| `assignmentEndTime` / `endTime` | 截止时间 |
| `assignmentStatus` | 状态 |

记录过滤：`type` 存在时仅保留 `3` 或 `5`（作业/测验）；否则默认视为作业。

截止时间解析：RFC3339（带时区）→ 归一为 `YYYY-MM-DD HH:MM:SS`；或 `YYYY-MM-DD HH:MM:SS` / `YYYY-MM-DD HH:MM`。

### 2.7 首页未完成（兜底合并）

```
GET https://apiucloud.bupt.edu.cn/ykt-site/site/student/undone?userId=<id>
```

响应 `data.undoneList[]` 每项：`activityId`（ID）、`activityName`（标题）、`type`（3|5=作业）、`endTime`（截止）。与课程作业按 `(id, deadline)` 去重合并，课程作业优先保留课程名。

### 2.8 作业状态映射

| 原始 | 展示 |
|---|---|
| `99` | 未提交 |
| `0` | 已提交 |
| `1` | 已批改 |
| `2` | 已驳回 |
| 其他字符串 | 原样 |

合并后按 `(deadline, course_name, title, id)` 升序排序。

---

## 3. 公共接口（无需登录）

### 3.1 班车

`GET https://where-to-study.cn/api/shuttle-bus`（schema_version `1.0`）。

选取规则 `active_shuttle_notice`：
1. 过滤 `published_at <= 今天` 的通知，按 `published_at` 降序、`id` 降序。
2. 每条通知内取 `parse_status=="parsed"` 且 `rows` 非空、且 `period.start_date <= 今天 <= (end_date|null)` 的 schedule。
3. 若某通知有 parsed 但当前时段无 active → 返回 None（不复活旧通知）。
4. 取 active 中 `period.start_date` 最新的那组 schedule。

展示：按 weekday（`monday..sunday`）取 `rows[].services.<weekday>.vehicle/count`，标记 `departed`（发车时间 <= 当前时刻）与 `next`（最早未发车）。

### 3.2 活动 / 竞赛 DDL

- 主源：`https://nemoyuzx.github.io/contest-ddl/data/competitions.json`（schema `1.4`，timezone `Asia/Shanghai`）
- 镜像：`https://where-to-study.cn/contest-ddl/data/competitions.json`
- 备用：`https://where-to-study.cn/api/contest-events`
- 校内：`https://where-to-study.cn/api/contest-notices`（schema `1.0`）

字段：`id`、`name`、`event_type`（六类 `competition/conference/journal_special_issue/hackathon/summer_camp/pre_admission`）、`primary_deadline`(RFC3339)、`categories[]`、`tags[]`、`organizer`、`official_url`、`level`、`location`、`description`、`source`。主/镜像按 `generated_at` 择新，均失败用备用。默认按 DDL 升序、隐藏已截止；`favorite_key = "<source_type>:<id>"`。

### 3.3 节假日

`GET https://unpkg.com/holiday-calendar@1.3.3/data/CN/<year>.json`：

```json
{ "year":2026, "region":"CN", "dates":[ {"date":"2026-01-01","name":"…","name_cn":"元旦","type":"public_holiday"} ] }
```

- `type`: `public_holiday`→`holiday`、`transfer_workday`→`workday`，其他跳过。
- 名称优先 `name_cn` 回退 `name`。
- 2026 内置离线兜底（`fallback_2026_items`，含元旦 1/1–1/3、元旦补班 1/4、春节补班 2/14、春节 2/15–2/23、春节补班 2/28、清明 4/4–4/6、劳动节 5/1–5/5、劳动节补班 5/9、端午 6/19–6/21、中秋 9/25–9/27、国庆补班 9/20、国庆 10/1–10/7、国庆补班 10/10）。

---

## 4. HTTP 传输安全约定

- 全部 HTTPS；固定 URL，不接受用户指定替代地址。
- `curl` 统一参数：`-sS`（静默但报错）、`--max-time <s>`（超时）、`--compressed`（gzip）、显式 `-H` 请求头。
- 响应大小上限：登录页 1MB、token 512KB、SJD 数据 4MB、班车 512KB、活动 4MB、节假日 256KB。
- 禁用自动重定向（`curl` 默认不跟随），需要时手动读取 `Location` 并校验 host。
- User-Agent 固定标识（如 `bupty/<version>`）。
