import SwiftUI

/// 根视图：未登录显示登录页，登录后显示底部 Tab（首页 / 课表 / 我的）。
/// iOS 26 的 TabView 自带 Liquid Glass 底栏，无需手写。
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    var body: some View {
        if appState.isLoggedIn {
            TabView(selection: $selectedTab) {
                Tab("首页", systemImage: "house.fill", value: 0) {
                    HomeView(selectedTab: $selectedTab)
                }
                Tab("课表", systemImage: "calendar", value: 1) {
                    ScheduleView()
                }
                Tab("我的", systemImage: "person.fill", value: 2) {
                    MineView()
                }
            }
            .tint(.white)
        } else {
            LoginView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
