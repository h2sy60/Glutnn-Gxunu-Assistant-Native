# Glutnn-Gxunu-Assistant-Native

桂工课程助手 —— **SwiftUI 原生重建**（iOS 26/27，Liquid Glass 用系统 `.glassEffect()`）。

## 为什么重建

Flutter 版（h2sy60/Glutnn-Gxunu-Assistant）已停：`real_liquid_glass` 在 iOS 26+ 是原生 `UiKitView` 平台视图，推子页面时平台视图层会盖住页面上的 Flutter 内容，转场中途页面像被撕开、穿模。Telegram 是原生 UIKit 所以没有这个问题。原生重建后，玻璃就是系统原生的，不再有这层问题。

## 当前状态：只有骨架

- 底部 Tab：首页 / 课表 / 我的
- 首页：深色壁纸占位 + 顶部 `.glassEffect()` 玻璃导航药丸
- 课表、我的：浅色不透明页面占位
- 登录、课表解析、成绩、考试、设置、导出等功能**下一步做**，不在这一版里

## 工程信息

- 语言：Swift 6，SwiftUI
- Deployment Target：iOS 26.0（需要 Xcode 26）
- Bundle ID：`com.h2sy60.GlutnnGxunuAssistant`（和 Flutter 版同一个包名，装新版前先删旧版）
- 显示名：桂工课程助手
- 版本：1.0.0（build 1）

## 构建（未签名 IPA）

每次推 `main`（改 `GlutnnGxunuAssistant/` 或工程文件）都会触发 GitHub Actions（macOS runner + `xcodebuild`，`CODE_SIGNING_ALLOWED=NO`），产物是 `Glutnn-Gxunu-Assistant-Native-unsigned-ipa`。每次构建成功后会自动删掉之前所有的旧构建，Actions 里只留最新一次构建（连同它的 IPA）。拿到 IPA 后用全能签 + 企业证书重签安装，和 Flutter 版一样。

本地构建（需要 Xcode 26）：

```sh
xcodebuild -project GlutnnGxunuAssistant.xcodeproj \
  -target GlutnnGxunuAssistant \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
```

## 学校

和 Flutter 版一样，两个学校，默认桂工：

- 桂林理工大学（GUT，jw.glutnn.cn）
- 广西职业师范学院（GXVNU，jw.gxvnu.edu.cn，正方教务系统）
