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
        // 提示条（原版 CustomSnackBar）：玻璃药丸浮在底部、低栏上方，点按执行动作或关掉。
        .overlay(alignment: .bottom) {
            if let toast = appState.toast {
                ToastPill(toast: toast) {
                    appState.handleToastTap()
                }
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.toast?.id)
    }
}

/// 提示条药丸（原版 CustomSnackBar 同款）：液态玻璃圆角 25，左图标 + 右文字。
/// “需要验证”的文字是蓝色的、可点的；其余是黑色 87。
struct ToastPill: View {
    let toast: Toast
    let onTap: () -> Void

    private var iconName: String {
        switch toast.kind {
        case .error: return "exclamationmark.circle"
        case .success: return "checkmark.circle"
        case .loading: return "link"
        case .info: return "star"
        }
    }

    private var iconColor: Color {
        switch toast.kind {
        case .error: return .red
        case .success: return .green
        case .loading: return .blue
        case .info: return .orange
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
                Text(toast.text)
                    .font(.system(size: 15))
                    .foregroundStyle(toast.action == nil ? Color.black.opacity(0.87) : Color.blue)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 25))
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
