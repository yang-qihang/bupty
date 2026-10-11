# UCloud 作业提交协议（功能 2 实现依据）

> 来源：官方前端静态分析 + 真实只读探测 + 1 次用户授权的真实提交实测。

## 通用请求头（与现有 ucloud 认证一致）

```
Authorization: Basic  cG9udGFsOnBvcnRhbF9zZWNyZXQ=   # 双空格 = portal:portal_secret
Tenant-Id: 000000
Blade-Auth: <access_token>
Referer: https://ucloud.bupt.edu.cn/
Accept: application/json, text/plain, */*
```

`userId` = oauth 响应 `userId` = `GET /ykt-basics/info` 的 `data.id`（实测一致）。

## 1. 提交作业

**POST `https://apiucloud.bupt.edu.cn/ykt-site/work/submit`**（Content-Type: application/json）

```json
{
  "attachmentIds": [],
  "assignmentContent": "作业内容纯文本，≤2000 字，去尾部空白",
  "assignmentId": "2104563317624279041",
  "assignmentType": 0,
  "userId": "1962944772575928394",
  "groupId": "",
  "commitId": ""
}
```

- `assignmentId` = `work/student/list` 的 `.id`；**没有 siteId**。
- `assignmentType`/`subGroupId` 从 `GET /ykt-site/work/detail` 拿。`groupId` = subGroupId（分组作业），个人作业空串。
- `commitId` 恒空串（前端拿不到该值）。
- 重交/补交与首次提交**接口与 body 完全相同**。

**成功**：HTTP 200 + `{"code":200,"success":true,"data":{},"msg":"操作成功"}`（前端判 `HTTP 200 && body.code==200`）。成功后该作业 `assignmentStatus` 变 0。
**失败**：HTTP 非 2xx 或 `body.code != 200`，错误取 `body.msg`。错误信封 `{"code":<int>,"success":false,"data":{},"msg":"..."}`。HTTP 401 / code==401 → token 过期。

## 2. 附件上传（先上传拿 resource id，再把 id 数组放进 attachmentIds）

**POST `https://apiucloud.bupt.edu.cn/blade-source/resource/upload/biz`**（multipart/form-data）

FormData 字段：`file`（单文件）、`userId`、`bizType`（固定 `3`）。

上传响应（推断）：`{"code":200,"success":true,"data":"<resourceId>","msg":"..."}`，`data` 即 resource id，`attachmentIds.push(data.data)`。

## 3. 附件约束（前端 uploadConfig 原文）

| 分类 | 扩展名白名单 | 单文件大小上限 |
|---|---|---|
| audio 音频 | mp3, m4a | 100 MB |
| video 视频 | mp4 | 200 MB |
| image 图片 | jpg, gif, png, jpeg | 20 MB |
| text 文档 | txt, doc, docx, pdf, xls, xlsx | 100 MB |
| text-ppt PPT | ppt, pptx | 300 MB |
| other 压缩包 | rar, zip | 3 GB |
| 数量 | — | 10 个 |

- 空文件（size 不 >0）拒绝：「文件大小至少1KB!」。
- 扩展名不匹配（转小写比对）：「不支持该格式文件上传!」。
- 超大小：「上传音频大小不能超过100MB!」等。
- 超数量（10）：「最多选择10个文件」。
- 校验是前端做的；后端是否再校验未验证——实现端做同样校验以对齐。

## 4. 前置只读接口

- `GET /ykt-site/work/detail?assignmentId=<id>` → `data` 含 `assignmentType`(0/1)、`subGroupId`、`isOvertimeCommit`(0=允许补交/1=不允许)、`assignmentStatus`、`status`(evaluationStatus: 1未开始/2进行中/3已结束)。
- `GET /ykt-site/work/submit-view?assignmentId=<id>` → 我的提交回显（提交前/后）。

## 5. 可提交判定（前端 showPage 逻辑）

- 不可提交：`status==3(已结束) && assignmentStatus==99(未提交) && isOvertimeCommit==1`。
- 其余（未结束；或已结束但 isOvertimeCommit==0 补交；或已提交未结束可重交）都可提交。

实现用简化判定：`can_submit = (status != 3) || (isOvertimeCommit == 0)`。

## 6. 实测记录

目标作业 `2104563317624279041`「第三次课作业」，提交 `assignmentContent` 测试文本 + `attachmentIds:[]`，返回 `{"code":200,"success":true,"data":{},"msg":"操作成功"}`，提交后 `assignmentStatus` 变 0。**需用户自行改回该测试内容。**
