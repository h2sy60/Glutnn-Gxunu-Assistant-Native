import SwiftUI

/// Glutnn-Gxunu-Assistant 原生重建入口。
/// 骨架：Tab（首页 / 课表 / 我的）+ 登录 / 课表等功能下一步做。
/// 全屏背景放在 WindowGroup 层（TabView 之上），背景铺满到屏幕边缘；各页内容仍留在安全区内。
@main
struct GlutnnGxunuAssistantApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.07, blue: 0.14),
                        Color(red: 0.10, green: 0.13, blue: 0.24),
                        Color(red: 0.07, green: 0.09, blue: 0.18),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ContentView()
                    .environment(appState)
            }
        }
    }
}
