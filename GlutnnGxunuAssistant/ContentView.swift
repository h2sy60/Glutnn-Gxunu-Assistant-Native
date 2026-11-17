import SwiftUI

/// 骨架：底部 Tab（首页 / 课表 / 我的）。
/// iOS 26 的 TabView 自带 Liquid Glass 底栏，无需手写。
/// TabView 忽略安全区，让各页背景铺满到屏幕边缘（状态栏 / Home Indicator 区域不再留黑边）；内容本身仍留在安全区内。
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("首页", systemImage: "house.fill") {
                HomeView()
            }
            Tab("课表", systemImage: "calendar") {
                ScheduleView()
            }
            Tab("我的", systemImage: "person.fill") {
                MineView()
            }
        }
        .tint(.white)
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
