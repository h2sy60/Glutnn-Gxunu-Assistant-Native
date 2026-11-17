import SwiftUI

/// 全屏背景：Flutter 版校园黄昏壁纸 + 深色渐变遮罩（B 方案同一套）。
/// 放在 WindowGroup 层（TabView 之上），铺满到屏幕边缘；各页内容仍留在安全区内。
struct WallpaperBackground: View {
    var body: some View {
        ZStack {
            if let data = wallpaperImageData(), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color(red: 0.05, green: 0.07, blue: 0.14)
                    .ignoresSafeArea()
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
        }
    }
}
