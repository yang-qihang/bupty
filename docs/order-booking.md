# BUPT 研修间预约协议（order.bupt.edu.cn）

> 来源：`order.bupt.edu.cn` 前端静态分析 + 用户授权（学号 2025211681）的真实登录 / 预约 / 取消实测。
> 所有请求均以 `https://order.bupt.edu.cn/ic-web` 为 base（`window.g.ApiUrl = '/ic-web'`，见 `config/config.js`，`loginMode: 2` = CAS 认证登录）。
> 通用响应信封：`{"code":<int>,"message":"...","data":...,"count":0,"vals":null}`。`code==0` 成功；`code==300` 未登录；其余 code 均为业务错误（message 为中文提示，可直接展示给用户）。

---

## 1. 登录 / 认证（CAS）

认证后的会话由两个东西组成：

- **Cookie `ic-cookie`**（会话 cookie，`HttpOnly`，Path=/）：真正的“登录态”。**所有 `reserve/*`、`auth/*`、`account/*` 接口都靠它**，缺了它返回 `code:300 用户未登录，请重新登录`。
- **请求头 `token`**：来自 `auth/userInfo` 返回的 `data.token`（32 位十六进制）。`roomMenu` / `seatMenu` / `sysConfig` 等菜单/配置接口靠它；带上它也可访问部分接口。

**结论：实现时两个都带上最稳（前端就是 `withCredentials:true` + 请求拦截器加 `token` 头）。** 另加 `lan: 1`（中文，1=中文/2=英文）。

### 完整 CAS 流程（真实跑通）

1. `GET /ic-web/auth/userInfo`（无 cookie）→ `{"code":300,"message":"用户未登录，请重新登录",...}`。
2. `GET /ic-web/auth/address?finalAddress=<urlencode(https://order.bupt.edu.cn/)>&manager=false&consoleType=16`
   返回 `data` = 登录跳转 URL：
   ```
   https://order.bupt.edu.cn/authcenter/toLoginPage?redirectUrl=<urlencode(https://order.bupt.edu.cn/ic-web//auth/token?uuid=<UUID>)>&queryParam=&typeCode=&extInfo=<UUID>
   ```
3. `GET <上一步 URL>`（跟随重定向）→ 302 到 CAS 登录页：
   `https://auth.bupt.edu.cn/authserver/login?service=<urlencode(https://order.bupt.edu.cn/authcenter/doAuth/<doAuthId>)>`
   同时 `Set-Cookie: UNI_AUTH_JSESSIONID=<...>`（order.bupt.edu.cn 域）。
4. `GET <CAS 登录页>` → 解析 HTML 里的 `<input name="execution" value="...">`。
5. `POST <CAS 登录页 URL>`，表单（`application/x-www-form-urlencoded`）：
   `username=2025211681` / `password=...` / `type=username_password` / `execution=<execution>` / `_eventId=submit`
   → 302，`Location` 带 `ticket=ST-...`，`Set-Cookie: CASTGC=TGT-...`（auth.bupt.edu.cn 域，可忽略）。
6. `GET https://order.bupt.edu.cn/authcenter/doAuth/<doAuthId>?ticket=ST-...`
   → 返回一个 HTML 页，内含 JS 跳转：
   `window.location.href = 'https://order.bupt.edu.cn/ic-web//auth/token?uuid=<UUID>&uniToken=<JWT>&extInfo=<UUID>'`
   （注意：是 HTML 里的 JS 跳转，**不是** HTTP 302，`curl -L` 不会自动跟，要自己解析这段字符串再 GET。）
7. `GET <上一步的 /ic-web//auth/token?uuid=...&uniToken=...>` → 302 到 `https://order.bupt.edu.cn/`，`Set-Cookie: ic-cookie=<UUID>`。
8. 现在 `GET /ic-web/auth/userInfo`（带 ic-cookie）→ `code:0`，`data` 含 `token`、`accNo`、`logonName`（学号）、`trueName` 等。`token` 存下来加请求头。

用户信息关键字段（实测）：`pid`/`logonName`=`2025211681`、`trueName`=杨某、`accNo`=`100000001`（**预约 body 里用的是 accNo，不是学号**）、`token`=`<32位hex>`、`uuid`、`deptName`、`kind=1`、`status=1`。

> 注意 CAS `execution` 与 `doAuth/<id>`、`uuid` 都是一次性的且绑定同一 cookie 会话（`UNI_AUTH_JSESSIONID`），必须**同一 cookie jar 内顺序执行**，不要并发/复用旧 execution。

---

## 2. 数据模型

### 2.1 分类（kind/lab）与「最少人数」

`GET /ic-web/roomMenu`（token 头即可）返回研修间分类树（西土城/沙河两个校区）。第二层节点的 `id` 就是**预约列表接口的 `labIds` 参数**（因为本部署 `spaceListType=2`）。

实测分类与人数下限（`minUser` / `maxUser`）：

| 分类（labIds） | 位置 | 房间示例 | minUser | maxUser |
|---|---|---|---|---|
| 100888904 | 沙河 一楼·朗读亭 | 朗读亭（沙河东侧/西侧） | **1** | 1 |
| 101346349 | 西土城 一楼·朗读亭 | 朗读亭（西土城） | 1 | 2 |
| 100651191 | 沙河 三楼·研讨间 | 314~318 | 2 | 4 |
| 100651215 | 沙河 四楼·研讨间 | 414~418 | 2 | 4 |
| 100651239 | 沙河 五楼·研讨间 | 514(**) / 515~518 | **1**(仅 514) | 4 |
| 105106622 | 西土城 红色主题阅览室 | 红色主题阅览室126 | 5 | 30 |

> **语义总结（用户所述完全属实）：**
> - 朗读亭：1 人即可（部分西土城朗读亭最多 2 人）。
> - 绝大多数研讨间：**最少 2 人**（`minUser=2`，最多 4 人）。
> - 少数研讨间只需 1 人：如**沙河五楼 514（devId=100651243，minUser=1,maxUser=4）**——已实测单人预约成功。
> - 主题阅览室（西土城）要 5 人起。
>
> `minUser`/`maxUser` 都在房间对象上（`GET /ic-web/reserve` 返回的每个 room 的字段），**不是**单独的分类字段。

### 2.2 房间 / 时段结构（`GET /ic-web/reserve` 返回）

每个房间（device）对象核心字段：

```jsonc
{
  "devId": 100888915,            // 预约 body 的 resvDev 用这个
  "devSn": 100888915,
  "devName": "朗读亭（沙河东侧）",
  "minUser": 1, "maxUser": 1,    // 最少/最多人数
  "kindId": 100888883, "kindName": "朗读亭（沙河校区）",
  "roomId": 100888914, "roomName": "朗读亭（沙河东侧）",
  "labId": 100888904, "labName": "一楼（沙河朗读亭）",
  "openStart": "08:00", "openEnd": "22:00",
  "openTimes": [ { "openStartTime": "08:00", "openEndTime": "22:00", "openLimit": 1 } ],
  "resvRule": {
     "ruleName": "朗读亭预约规则（沙河）",
     "classKind": 1,            // 1=研修间
     "minResvTime": 10,         // 最少预约时长（分钟）
     "maxResvTime": 30,         // 最多预约时长（分钟）；研讨间=120
     "earliestResvTime": 5760,  // 最早可提前多少分钟预约（朗读亭=4天，研讨间=2160=1.5天）
     "latestResvTime": 0,
     "cancelTime": 10,          // 需在开始前多少分钟取消（研讨间=15）
     "timeInterval": 5,         // 时间步长（分钟）
     "limit": 260               // 位掩码：控制主题/备注/附件是否必填等
  },
  "resvInfo": [                 // 已占用的预约（用于算空闲时段）
     { "uuid":"...", "resvId":107676821,
       "startTime": 1791892800000, "endTime": 1791899400000,  // epoch 毫秒
       "title":"其他", "trueName":"张*文", "logonName":"2********7",
       "resvStatus": 1027, "devId": 100651195 }
  ]
}
```

**空闲时段 = `openTimes` 覆盖区间 减去 `resvInfo` 里各预约的 `[startTime,endTime]`**，再按 `resvRule.timeInterval` 步进、夹在 `minResvTime`~`maxResvTime` 之间。没有独立的“segment id”，前端就是这么算的（TUI 照做即可）。

`resvStatus` 是位掩码（用于“我的预约”列表渲染）：`4`=已签到相关、`64`=进行中/已签到、`128`=已结束/已取消、`256`=可编辑、`512`=有违约记录、`1024`=需确认、`8192`=待同意（多人预约时他人待确认）。新建成功的预约 `resvStatus=1027`（=1024+2+1 组合，正常待履约状态）。

---

## 3. 核心接口

### 3.1 列出分类 `roomMenu`

`GET /ic-web/roomMenu`（header: `token`, `lan`）

返回：`data` = 校区→分类树（见 2.1）。用第二层 `id` 作 `labIds`。

### 3.2 列房间 + 空闲时段 `reserve`（GET）

`GET /ic-web/reserve?sysKind=1&labIds=<分类id>&resvDates=<YYYYMMDD,YYYYMMDD>`
（本部署 `spaceListType=2` 用 `labIds`；`spaceListType=1/3` 时用 `kindIds`，`=3` 再加 `campusId`。可用 cookie 认证。）

- `resvDates` 是**闭区间** `开始,结束`（如 `20261014,20261014` 只查一天，`20261013,20261031` 查本月）。前端默认「今天 ~ 本月底」。
- 返回 `data` = 房间数组（含 `openTimes`、`resvInfo`、`resvRule`、`minUser/maxUser`，见 2.2）。要查某一天，就取 `resvInfo` 里落在该天的预约来算空闲。

### 3.3 预约 `reserve`（POST）

`POST /ic-web/reserve`（cookie `ic-cookie` + header `token`/`lan`，`Content-Type: application/json`）

请求 body（前端 `submitDate` 原文逻辑，**resvBeginTime/resvEndTime 是 `YYYY-MM-DD HH:mm:00` 带连字符**）：

```jsonc
{
  "sysKind": 1,                    // 1=研修间（朗读亭/研讨间都是 1）
  "appAccNo": 100000001,           // 发起人 accNo（= auth/userInfo 的 accNo）
  "memberKind": 1,                 // 1=仅本人；2=带成员（>1 人时）
  "resvBeginTime": "2026-10-14 14:00:00",
  "resvEndTime":   "2026-10-14 14:30:00",
  "testName": "科研讨论",           // 主题，必填（可选值见 3.6）
  "resvKind": 2,                   // 前端固定 2
  "resvProperty": 0,               // 研修间固定 0
  "appUrl": "",                    // 附件/链接（通常空）
  "resvMember": [100000001],       // accNo 数组；多人 = [本人accNo, 他人accNo, ...]
  "resvDev": [100888915],          // devId 数组
  "memo": "",
  "captcha": "",                   // resvCode=0 时留空
  "addServices": []                // 附加服务，通常空
}
```

- **单人（朗读亭 / 514 这类 minUser=1）**：`memberKind:1`，`resvMember:[自己accNo]`。已实测成功。
- **多人（普通研讨间 minUser=2）**：`memberKind:2`，`resvMember:[自己accNo, 他人accNo]`。他人 accNo 通过 3.5 的 `account/getMembers` 用学号查（**只需学号，不要对方密码**；后端会解析出姓名）。已实测 2025211681+<另一学号> 预约 314 成功，列表回显两位成员 `kind=65`。

成功响应：`code:0, message:"新增成功"`，`data` = 完整预约对象（含 `uuid`、`resvId`、`resvStatus=1027`、`resvBeginTime/EndTime`(epoch ms)、`resvDevInfoList[0].devName` 等，见文末实测样例）。

### 3.4 取消 `reserve/delete`（POST）

`POST /ic-web/reserve/delete`，body `{"uuid": "<预约uuid>"}`（`Content-Type: application/json`）。

成功：`{"code":0,"message":"删除成功","data":null,"count":0,"vals":null}`。取消用**预约的 `uuid`**（不是 resvId）。

相关备用接口（前端其它入口用到，参数都带 `uuid`）：
- `POST /ic-web/reserve/endAhaed` body `{"uuid":...}` —— “提前结束”（履约中提前离场）。
- `POST /ic-web/reserve/endReserve` body `{"resvId":...}` —— 签离/结束。

### 3.5 查他人 accNo `account/getMembers`（GET）

`GET /ic-web/account/getMembers?key=<学号>&page=1&pageNum=10`（cookie 认证）

返回 `data[0].accNo`（= 他人 accNo，填进 resvMember）、`logonName`（脱敏学号）、`trueName`、`status`/`localstatus`（`2` = 停用，前端会置灰不可选）。

### 3.6 主题列表 `devCoding/theme/details`（GET）

`GET /ic-web/devCoding/theme/details?devId=<devId>` → `data` 为 `{codeName, codeValue}` 数组。实测可选主题：科研讨论(1)、学术交流(2)、课程研讨(3)、读书会(4)、社团活动(5)、大创研讨(6)、其他(7)。`testName` 填 `codeName`（如「科研讨论」）。

### 3.7 我的预约列表 `reserve/resvInfo`（GET）

`GET /ic-web/reserve/resvInfo?beginDate=YYYY-MM-DD&endDate=YYYY-MM-DD&needStatus=<位掩码和>&page=1&pageNum=10&orderKey=gmt_create&orderModel=desc`

- `needStatus`：前端默认 `2+4=6`（= 待履约+已预约）。要「全部」可给更大掩码（如 `2|4|256|128|...`）。
- 返回 `data` = 预约数组（含 `uuid`、`resvId`、`resvStatus`、`resvBeginTime/EndTime`、`resvDevInfoList[0].devName`、`resvMemberInfoList[]`、`memberKind`），`count` = 总数。

> 任务提示里的 `/borrow/reserve/own` 是「外借设备」的列表（参数 `page/pageSize`），**不是**研修间的列表。研修间「我的预约」用 `reserve/resvInfo`。

### 3.8 预约计数 `reserve/count`（GET）

`GET /ic-web/reserve/count` → `data` = 当前生效预约数（实测无预约时 `data:0`）。可用于预判「连续预约」限制。

### 3.9 违约/禁用名单 `reserve/punishInfo`（GET）

`GET /ic-web/reserve/punishInfo` → `data` = 数组，每项 `{classKind, ...}`（被禁用的系统类别，1=研修间）。空数组 = 无违约/未禁用。前端登录后拉取并展示“禁用”提示条；**真正拦截在预约接口**——被禁用时预约 POST 会直接返回业务错误（`code!=0`，message 为服务器给的提示，前端原样 `$message.error(t.message)` 展示）。

---

## 4. 规则与错误（实测）

### 4.1 「同一时间只能有一个预约 / 不能连续预约」（已实测触发）

已有 1 个未取消预约时，再预约第二个，返回：

```json
{"code":1,"message":"不能连续预约","data":null,"count":0,"vals":null}
```

即：**研修间同一用户同时只能持有 1 个预约**（“one advance slot per self-booking”）。先取消再约即可。

### 4.2 违约 / no-show 禁用

未实测触发（该账号当前 `punishInfo` 为空，无违约记录）。机制：登录后 `GET /ic-web/reserve/punishInfo` 返回非空即被禁；预约 POST 会由后端拒绝并返回带提示的 `code!=0`。前端不会做本地拦截，直接展示服务器 `message`。TUI 实现同样：预约前拉 `punishInfo`，非空则提示，并信任预约接口的错误 message。

### 4.3 其他已确认错误

- 未登录（缺 cookie）：`code:300, message:"用户未登录，请重新登录"`。
- 参数缺失（如 `/borrow/reserve/own` 缺分页）：`code:100, message:"分页参数为空"`。
- `reserve/time/expand` 缺参数：`code:1, message:"请选择相应的数据"`。

---

## 5. 备用/未完全逆向的接口（前端 JS 已定义）

这些接口在 `chunk-d5f0defc` 的 API 模块里都有定义，但不是研修间主流程，本任务未逐个用真实参数跑通：

| 方法 | 路径 | 用途（静态分析） |
|---|---|---|
| GET | `/ic-web/reserve/entrance` | 研修间入口列表（本部署实测任意参数均 `code:500`，疑似移动端/旧路径） |
| POST | `/ic-web/reserve/entrance/save` | 入口保存 |
| POST | `/ic-web/reserve/time/expand` | 展开可用时段（分段；本部署返回「请选择相应的数据」） |
| GET | `/ic-web/reserve/time/expand/duration` | 时段时长展开（返回「请求参数缺失」） |
| POST | `/ic-web/reserve/update` | 修改预约（`resvId`、`resvMember`、`resvBeginTime/EndTime`、`testName`、`addServices`） |
| POST | `/ic-web/reserve/quickResv` | 快速预约 |
| GET | `/ic-web/room/openTimes` | 房间开放时段 |
| GET | `/ic-web/reserve/endList` | 已结束预约列表 |
| POST | `/ic-web/reserve/endReserve` | 结束/签离（body `resvId`） |
| POST | `/ic-web/reserve/endAhaed` | 提前结束（body `uuid`） |
| GET | `/ic-web/reserve/getSignRec` | 签到记录 |
| GET | `/ic-web/reserve/seatArea` | 座位区域（座位模块） |
| GET | `/ic-web/borrow/reserve/own` | 外借设备我的预约（`beginDate,endDate,page,pageSize`） |
| GET | `/ic-web/borrow/device/resvDevInfo` | 外借设备信息 |
| POST | `/ic-web/reserve/upload` | 附件上传（`/reserve/upload`） |

---

## 6. 实测记录（授权，已全部取消，无残留预约）

1. 登录 2025211681 → `ic-cookie` + `token`。
2. 朗读亭（沙河东侧，devId 100888915，minUser=1）：预约明天 14:00-14:30 → `新增成功`，uuid `2ea545a5...`，resvId 107677268。
3. 立即尝试第二个预约（15:00-15:30）→ `{"code":1,"message":"不能连续预约"}`（触发单预约限制）。
4. 取消第一个 → `reserve/delete {"uuid":"2ea545a5..."}` → `删除成功`；`reserve/resvInfo` 回到 `count:0`。
5. 特殊 1 人研讨间 514（devId 100651243，minUser=1）：预约明天 08:00-10:00 → `新增成功`（uuid 890676e9...）→ 已取消。
6. 普通 2 人研讨间 314（devId 100651195，minUser=2）：`memberKind:2, resvMember:[100000001, 100000002]`（2025211681 + <另一学号>）预约明天 11:30-13:00 → `新增成功`（uuid 0a287e38...，列表回显两位成员）→ 已取消。
7. 最终 `reserve/resvInfo` 确认为空：**没有遗留任何预约**。

### 预约成功响应样例（朗读亭，删减保留关键字段）

```json
{
  "code": 0, "message": "新增成功",
  "data": {
    "uuid": "2ea545a5bdc840218f472b34def1b8c6",
    "resvId": 107677268,
    "appAccNo": 100000001,
    "memberKind": 1,
    "resvDate": 20261014,
    "resvBeginTime": 1791957600000,
    "resvEndTime": 1791959400000,
    "resvStatus": 1027,
    "classKind": 1,
    "testName": "科研讨论",
    "resvKind": 16,
    "logonName": "2025211681",
    "resvName": "杨某",
    "resvDevInfoList": [{
      "resvId": 107677268, "devId": 100888915,
      "devName": "朗读亭（沙河东侧）", "devSn": 100888915,
      "kindId": 100888883, "kindName": "朗读亭（沙河校区）",
      "roomId": 100888914, "roomName": "朗读亭（沙河东侧）",
      "labId": 100888904, "labName": "一楼（沙河朗读亭）",
      "classKind": 1, "campusId": 1
    }],
    "resvMemberInfoList": null,
    "endEarly": false
  },
  "count": 0, "vals": null
}
```
