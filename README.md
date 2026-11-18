# Glutnn-Gxunu-Assistant-Native

周周有善 —— SwiftUI（iOS 26，Liquid Glass 用系统 `.glassEffect()`）。

## 截图

| 一览 | 课表 | 我的 |
| --- | --- | --- |
| <img src="screenshots/home.jpg" width="250"> | <img src="screenshots/schedule.jpg" width="250"> | <img src="screenshots/mine.jpg" width="250"> |

## 功能

### 双学校

- 桂林理工大学、广西职业师范学院，登录页选学校
- 账号按学校分开保存，切学校自动换回该校的账号和课表

### 首页

- 今日课程 / 明日课程，正在上的那节高亮显示
- 一键刷新课表、查成绩、看考试；职师院多一个“更多”（毕业进度、学分、教学计划、培养方案、评教、毕设、待办、通知公告、个人信息、学籍预警）

### 课表

- 周课表，左右滑动切换周
- 点课程块弹出详情卡片（教师、地点、周数、时间、备注）
- 导出到系统日历（按课程生成日程，上课前 15 分钟提醒）

### 课表设置（我的 → 课表设置）

- 实时预览：改一项，预览立刻变
- 文字：颜色、深浅、字号
- 格子内容：显示上课时间 / 上课地点 / 教室前 @ / 授课老师 / 备注
- 格子外观：圆角半径、不透明度
- 一键恢复默认
- 设置按学校 + 学号保存，登录就是你调好的那套，再调就覆盖

### 成绩

- 成绩列表，平均绩点 / 平均分
- 学年、学期筛选（顶栏选择器）

### 考试

- 考试安排查询

### 更多（职师院专属，首页 → 更多）

- 毕业进度：总要求学分与已修得、在修、还差，按课程性质拆分
- 学分：已选课程与总学分
- 教学执行计划：本学院各专业培养方案概览，本专业有标记
- 培养方案：官方培养方案 PDF，点开直接看
- 学生评教：待评课程与提交情况（打分请在教务网页完成）
- 毕设：已选题数与选题列表（大一为空）
- 待办事项：调课、补课等提醒，未读有蓝点
- 通知公告：学校通知，只读列表，点开看全文
- 个人信息：年级、学院、专业、班级与照片
- 学籍预警：风险课程与预警学分，没有预警会显示对勾

### 我的

- 个人信息、当前周、学期
- 切换账号、导出日志、退出登录

## 学校

两个学校，默认桂工：

- 桂林理工大学（GUT，jw.glutnn.cn）
- 广西职业师范学院（GXVNU，jw.gxvnu.edu.cn，正方教务系统）

## 工程信息

- 语言：Swift 6，SwiftUI
- Deployment Target：iOS 26.0（需要 Xcode 26）
- Bundle ID：`com.h2sy60.GlutnnGxunuAssistant`
- 显示名：周周有善
- 版本：1.0.0（build 59）

## 构建（未签名 IPA）

每次推 `main`（改 `GlutnnGxunuAssistant/` 或工程文件）都会触发 GitHub Actions（macOS runner + `xcodebuild`，`CODE_SIGNING_ALLOWED=NO`），产物是 `Glutnn-Gxunu-Assistant-Native-unsigned-ipa`。每次构建成功后会自动删掉之前所有的旧构建，Actions 里只留最新一次构建（连同它的 IPA）。拿到 IPA 后用全能签 + 企业证书重签安装。

本地构建（需要 Xcode 26）：

```sh
xcodebuild -project GlutnnGxunuAssistant.xcodeproj \
  -target GlutnnGxunuAssistant \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
```
