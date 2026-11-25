import SwiftUI

/// 全屏背景：Flutter 版校园黄昏壁纸 + 深色渐变遮罩（B 方案同一套）。
/// 放在 WindowGroup 层（TabView 之上），铺满到屏幕边缘；各页内容仍留在安全区内。
/// build 63 首页设置可换壁纸：0=校园黄昏照片（默认），1=深蓝渐变，2=墨绿渐变，3=纯黑。
/// build 69：4=自定义照片（相册选图，存 Documents/custom-wallpaper.jpg；没存过退回校园黄昏）。
/// build 71：自定义壁纸版本号——每次存新图 +1，强制所有 WallpaperBackground
/// 重读文件。wallpaper 已经是 4 时再选新图，Int 不变不会触发重绘，旧图就
/// 一直挂着（主页换了、我的页没换；Russell 2026-11-19 11:04 截图）。
/// build 79：删掉 @Environment(AppState.self)——build 78 的启动闪退就是它。
/// 崩溃报告（2026-11-19 16:02:31，build 78，启动后 0.18 秒）：EXC_BREAKPOINT，
/// 崩溃帧 EnvironmentValues.subscript.getter → _assertionFailure。
/// SwiftUI 在更新 @Environment 属性时，不管 body 用不用它，都会先去环境里
/// 取值，取不到就直接断言崩。WindowGroup 的 .background() 里挂的
/// WallpaperBackground 拿不到 AppState（.environment() 透不进 background），
/// 一点开 app 就崩。build 77 用 @AppStorage 没这个问题，build 78 换成
/// @Environment 才崩的。
/// 修法：壁纸彻底不要环境，全部显式传参。四个调用点都传
/// appState.wallpaper / appState.customWallpaperVersion，AppState 一变父视图
/// 重算、壁纸跟着重建，换壁纸照样立即生效。
struct WallpaperBackground: View {
    private let wallpaper: Int
    private let customVersion: Int
    @State private var cachedImage: UIImage?
    
    init(wallpaper: Int, customVersion: Int) {
        self.wallpaper = wallpaper
        self.customVersion = customVersion
    }

    private var currentWallpaper: Int { wallpaper }
    private var currentVersion: Int { customVersion }

    /// 默认照片壁纸（校园黄昏）。自定义图没存过时也退回它。
    private var defaultPhotoBackground: some View {
        Group {
           if let uiImage = cachedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(red: 0.05, green: 0.07, blue: 0.14)
            }
        }
    }

    var body: some View {
        // Color.clear 是纯弹性视图，配最外层 .ignoresSafeArea() 严丝合缝铺满
        // 物理全屏，绝无底部黑边；所有照片/渐变都在 .overlay 里，宽版/横版图
        // .scaledToFill() 绝不会把任何父/兄弟视图顶偏，再由 .clipped() 裁掉
        // 超出屏幕的两侧。allowsHitTesting(false)：壁纸不拦截点击。
        Color.clear
            .overlay {
                ZStack {
                    wallpaperLayer
                    // 深色遮罩：顶部 0x8C → 0x26 @0.3 → 0x38 @0.65 → 0xD9 底部（原样保留）。
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
                }
                .id("\(currentWallpaper)-\(currentVersion)")
            }
            .clipped()
            .allowsHitTesting(false)
            .ignoresSafeArea()
        .task(id: "\(currentWallpaper)-\(currentVersion)") {
            let targetWallpaper = currentWallpaper
            let decoded = await Task.detached(priority: .userInitiated) { Self.decodeWallpaper(for: targetWallpaper) }.value
            if !Task.isCancelled { cachedImage = decoded }
        }    
        }

    @ViewBuilder
    private var wallpaperLayer: some View {
        switch currentWallpaper {
        case 1:
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.12, blue: 0.28), Color(red: 0.02, green: 0.05, blue: 0.12)],
                startPoint: .top, endPoint: .bottom
            )
        case 2:
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.2, blue: 0.14), Color(red: 0.02, green: 0.08, blue: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
        case 3:
            Color(red: 0.03, green: 0.03, blue: 0.04)
        case 4:
           defaultPhotoBackground
        default:
            defaultPhotoBackground
        }
    }
    nonisolated private static func decodeWallpaper(for targetWallpaper: Int) -> UIImage? {
        if targetWallpaper == 1 || targetWallpaper == 2 || targetWallpaper == 3 { return nil }
        if targetWallpaper == 4, let data = customWallpaperData(), let image = UIImage(data: data) { return image }
        return wallpaperImageData().flatMap { UIImage(data: $0) }
    }    
    }

/// Glutnn-Gxunu-Assistant 原生重建入口。
@main
struct GlutnnGxunuAssistantApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                // 壁纸挂 .background（build 77 起，保住系统浮动底栏）；build 78
                // 改用新版闭包 .background { ... } 并显式传参，appState.wallpaper
                // 一变 WindowGroup 重算、background 跟着重建，换壁纸必刷新。
                // 旧版 .background(View) 重载在 iOS 26 上不跟 @AppStorage 重建，
                // 是 build 77 换壁纸卡死的原因之一。
                .background {
                    WallpaperBackground(
                        wallpaper: appState.wallpaper,
                        customVersion: appState.customWallpaperVersion
                    )
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
            // build 85：回到前台时重算当前周——currentWeek 只在启动/切校/
            // 改学期设置时算一次就缓存，App 在后台跨了周（2026-11-23 周一
            // 仍显示第 11 周）就一直错下去；日期胶囊是现算的，所以它对、
            // 周数和星期条错。回前台就重算，首页 + 课表都跟着对。
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    appState.refreshCurrentWeek()
                }
            }
        }
    }
}
