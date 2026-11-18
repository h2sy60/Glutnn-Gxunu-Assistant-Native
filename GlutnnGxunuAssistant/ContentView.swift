import SwiftUI

/// 根视图：三个 Tab 常驻（一览 / 课表 / 我的），不登录也能进。
/// 旧版 Flutter 就是这样：启动读本地缓存直接进首页，登录只是 push 进来的一个页面，
/// 右上角有关闭钮；只有点刷新/成绩/考试且未登录时，才弹登录页。
/// iOS 26 的 TabView 自带 Liquid Glass 底栏，无需手写。
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("一览", systemImage: "house.fill", value: 0) {
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
        .fullScreenCover(isPresented: Binding(
            get: { appState.showLoginSheet },
            set: { appState.showLoginSheet = $0 }
        )) {
            LoginView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
