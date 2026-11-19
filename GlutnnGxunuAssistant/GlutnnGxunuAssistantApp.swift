import SwiftUI

/// 全屏背景：Flutter 版校园黄昏壁纸 + 深色渐变遮罩（B 方案同一套）。
/// 放在 WindowGroup 层（TabView 之上），铺满到屏幕边缘；各页内容仍留在安全区内。
/// build 63 首页设置可换壁纸：0=校园黄昏照片（默认），1=深蓝渐变，2=墨绿渐变，3=纯黑。
/// build 69：4=自定义照片（相册选图，存 Documents/custom-wallpaper.jpg；没存过退回校园黄昏）。
/// 用 @AppStorage 读同一个键，设置页一改这里立即重绘。
struct WallpaperBackground: View {
    @AppStorage("Wallpaper") private var wallpaper = 0

    /// 默认照片壁纸（校园黄昏）。自定义图没存过时也退回它。
    private var defaultPhotoBackground: some View {
        Group {
            if let data = wallpaperImageData(), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color(red: 0.05, green: 0.07, blue: 0.14)
                    .ignoresSafeArea()
            }
        }
    }

    var body: some View {
        ZStack {
            switch wallpaper {
            case 1:
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.12, blue: 0.28), Color(red: 0.02, green: 0.05, blue: 0.12)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            case 2:
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.2, blue: 0.14), Color(red: 0.02, green: 0.08, blue: 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            case 3:
                Color(red: 0.03, green: 0.03, blue: 0.04)
                    .ignoresSafeArea()
            case 4:
                if let data = customWallpaperData(), let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                } else {
                    defaultPhotoBackground
                }
            default:
                defaultPhotoBackground
            }
            // 深色遮罩：顶部 0x8C → 0x26 @0.3 → 0x38 @0.65 → 0xD9 底部。
            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.85),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

/// Glutnn-Gxunu-Assistant 原生重建入口。
@main
struct GlutnnGxunuAssistantApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ZStack {
                WallpaperBackground()
                ContentView()
                    .environment(appState)
            }
            // 窗口级亮/暗模式跟着当前 Tab 走：课表是白底页，窗口切亮色，
            // 系统底栏（UITabBar，只认窗口 trait）就变浅色玻璃；
            // 首页/我的切回深色，白字才看得见。
            // 依据：TabView 是 UITabBarController 的包装，底栏是 UITabBar，
            // TabView 上的 .preferredColorScheme 只影响 SwiftUI 子树、不动底栏
            // （build 32 实测）；窗口级 .preferredColorScheme 改的是窗口 trait，
            // 底栏跟着翻。WWDC25 219/323：小号玻璃铬随背景在浅色↔深色之间翻转。
            .preferredColorScheme(appState.selectedTab == 1 ? .light : .dark)
            .task {
                // 启动恢复：有已存账号就自动登录（职师院直接进，桂工预填 + 取验证码图）。
                await appState.tryAutoLogin()
            }
        }
    }
}
