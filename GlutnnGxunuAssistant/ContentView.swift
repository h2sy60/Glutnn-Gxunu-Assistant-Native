import SwiftUI
import UIKit // 仅用于把验证码图片 Data 解成 UIImage 再交给 SwiftUI Image 显示。

/// 根视图：三个 Tab 常驻（一览 / 课表 / 我的），不登录也能进。
/// 旧版 Flutter 就是这样：启动读本地缓存直接进首页，登录只是 push 进来的一个页面，
/// 右上角有关闭钮；只有点刷新/成绩/考试且未登录时，才弹登录页。
/// 底栏是手写的悬浮玻璃条（build 33）：系统 TabView 的底栏不跟
/// .preferredColorScheme 走（build 32 实测：在课表页切亮色也没用，底栏还是深灰），
/// 只有自己画的玻璃才能用 tint 精确控制深浅——课表白底页用浅色玻璃，
/// 首页/我的深色壁纸用深色玻璃（和课表页导出/日期药丸同一招，管用）。
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    /// 课表页时底栏要浅色玻璃，其余页深色玻璃。
    private var isLightBar: Bool { selectedTab == 1 }

    /// 底栏玻璃：浅色页加白 tint，深色页用默认深色玻璃。
    private var tabBarGlass: Glass {
        isLightBar ? .regular.tint(.white.opacity(0.75)) : .regular
    }

    private func tabItemIconColor(selected: Bool) -> Color {
        if isLightBar {
            return selected ? Color.black.opacity(0.87) : Color.black.opacity(0.5)
        }
        return selected ? .white : .white.opacity(0.7)
    }

    /// 手写悬浮底栏：三项（图标 + 文字），选中项背后一颗灰色小胶囊。
    private func tabBar() -> some View {
        HStack(spacing: 0) {
            ForEach([(0, "house.fill", "一览"), (1, "calendar", "课表"), (2, "person.fill", "我的")], id: \.0) { item in
                Button {
                    selectedTab = item.0
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.1)
                            .font(.system(size: 22, weight: .semibold))
                        Text(item.2)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tabItemIconColor(selected: selectedTab == item.0))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == item.0
                            ? Color.gray.opacity(0.3)
                            : Color.clear,
                        in: Capsule()
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(tabBarGlass, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    var body: some View {
        ZStack {
            // 三页常驻（opacity 藏起来、关掉点按，@State 不丢）：
            // 切 Tab 不重建页面，课表当时看的周、首页的状态都留着。
            HomeView(selectedTab: $selectedTab)
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)
            ScheduleView()
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
            MineView()
                .opacity(selectedTab == 2 ? 1 : 0)
                .allowsHitTesting(selectedTab == 2)

            // 悬浮底栏钉在底部。
            VStack {
                Spacer()
                tabBar()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { appState.showLoginSheet },
            set: { appState.showLoginSheet = $0 }
        )) {
            LoginView()
        }
        // 验证码弹窗（原版 dialog.dart showCaptchaDialog 同款）：居中白卡，
        // 不是整页登录。放在提示条下面一层，提示条（“验证码错误!”）永远盖在最上面。
        .overlay {
            if appState.showCaptchaDialog {
                CaptchaDialogView()
            }
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

/// 验证码弹窗（原版 dialog.dart showCaptchaDialog 同款）：
/// 标题“提示” + “输入验证码后继续” + 验证码输入行（魔棒图标 + 输入框 + 图片点按换一张）
/// + 取消 / 继续。成功后重登并重拉数据；验证码错留在弹窗里换图重试。
struct CaptchaDialogView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var captchaFocused: Bool

    var body: some View {
        ZStack {
            // 遮罩（原版 showDialog 黑 38%）：点空白处关掉弹窗。
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    if !appState.captchaChecking {
                        appState.showCaptchaDialog = false
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                Text("提示")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                Text("输入验证码后继续")
                    .font(.system(size: 15))
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                    TextField("验证码", text: Binding(
                        get: { appState.captchaDialogText },
                        set: { appState.captchaDialogText = $0 }
                    ))
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($captchaFocused)
                    .foregroundStyle(.black)
                    Spacer()
                    if let data = appState.captchaImageData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 25)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture {
                                Task { await appState.fetchCaptcha() }
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 80, height: 25)
                            .overlay(Text("点我刷新").font(.caption).foregroundStyle(.gray))
                            .onTapGesture {
                                Task { await appState.fetchCaptcha() }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Divider()
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                HStack {
                    Spacer()
                    if !appState.captchaChecking {
                        Button("取消") {
                            appState.showCaptchaDialog = false
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)
                        .padding(.trailing, 24)
                    }
                    Button(appState.captchaChecking ? "稍等..." : "继续") {
                        Task { await appState.confirmCaptchaDialog() }
                    }
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .disabled(appState.captchaChecking)
                }
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 26))
            .padding(.horizontal, 32)
        }
        .onAppear { captchaFocused = true }
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
        // 原版提示条永远是浅色玻璃 + 深色字（哪怕在深色壁纸首页上也是）；
        // 整 App 强制深色模式会让它变成深色玻璃，深色字就看不清了。
        .preferredColorScheme(.light)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
