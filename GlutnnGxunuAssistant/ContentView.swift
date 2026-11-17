import SwiftUI

/// 骨架：底部 Tab（首页 / 课表 / 我的）。
/// iOS 26 的 TabView 自带 Liquid Glass 底栏，无需手写。
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
    }
}

#Preview {
    ContentView()
}
