import SwiftUI
import UIKit // 仅用于把验证码图片 Data 解成 UIImage 再交给 SwiftUI Image 显示。

/// 根视图：三个 Tab（一览 / 课表 / 我的），不登录也能进。
/// 旧版 Flutter 就是这样：启动读本地缓存直接进首页，登录只是 push 进来的一个页面，
/// 右上角有关闭钮；只有点刷新/成绩/考试且未登录时，才弹登录页。
/// 用系统 TabView（iOS 26 液态玻璃底栏）。build 33 曾改成手写底栏，
/// Russell 明确不要——系统底栏才是对的，颜色问题另想办法，不许再自己画底栏。
struct ContentView: View {
    @Environment(AppState.self) private var appState

    /// Tab 选中态存在 AppState（不是本地 @State），因为 App 入口的窗口级
    /// .preferredColorScheme 要读它——系统底栏（UITabBar）只跟窗口走。
    private var selectedTab: Binding<Int> {
        Binding(get: { appState.selectedTab }, set: { appState.selectedTab = $0 })
    }

    var body: some View {
        TabView(selection: selectedTab) {
            HomeView(selectedTab: selectedTab)
                .tabItem { Label("一览", systemImage: "house.fill") }
                .tag(0)
            ScheduleView()
                .tabItem { Label("课表", systemImage: "calendar") }
                .tag(1)
            MineView()
                .tabItem { Label("我的", systemImage: "person.fill") }
                .tag(2)
        }
        .fullScreenCover(isPresented: Binding(
            get: { appState.showLoginSheet },
            set: { appState.showLoginSheet = $0 }
        )) {
            LoginView().overlay(alignment: .bottom) { globalToastOverlay }
        }
        // 验证码弹窗（原版 dialog.dart showCaptchaDialog 同款）：居中白卡，
        // 不是整页登录。放在提示条下面一层，提示条（“验证码错误!”）永远盖在最上面。
        .overlay {
            if appState.showCaptchaDialog {
                CaptchaDialogView()
            }
        }
        // 提示条（原版 CustomSnackBar）：玻璃药丸浮在底部、低栏上方，点按执行动作或关掉。
        .overlay(alignment: .bottom) { globalToastOverlay
        }
    }
    @ViewBuilder
    private var globalToastOverlay: some View {
        ZStack {
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
    @State private var isRefreshingCaptcha = false
    @State private var cachedCaptchaImage: UIImage?

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

                // 验证码输入框（build 39 重设计）：整个输入行做成一个玻璃框，
                // 图标 + 输入框 + 验证码图都在框里，图在框内右侧、不贴弹窗边
                // （Russell 2026-11-18 14:48：之前图太靠右、快出去了）。
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                    TextField("验证码", text: Binding(
                        get: { appState.captchaDialogText },
                        set: { appState.captchaDialogText = $0 }
                    ))
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        guard !appState.captchaChecking else { return }
                        Task { await appState.confirmCaptchaDialog() }
                    }
                    .focused($captchaFocused)
                    .foregroundStyle(.black)
                if let uiImage = cachedCaptchaImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 25)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture {
                            refreshCaptcha()
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 80, height: 25)
                            .overlay(Text("点我刷新").font(.caption).foregroundStyle(.gray))
                            .onTapGesture {
                            refreshCaptcha()
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.clear.tint(.white.opacity(0.5)), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // 取消 / 继续（build 39 重设计，build 76 加高）：两个等宽液态玻璃胶囊并排，
                // 不再是贴右的蓝色文字——之前“继续”贴右沿、快出弹窗了。
                // 胶囊比弹窗底色略实（白 0.5 对 0.35），看得出是两个钮。
                // build 76：按钮 44→52 高，好点；玻璃改 .clear，模糊降下来。
                HStack(spacing: 12) {
                    Button("取消") {
                        if !appState.captchaChecking {
                            appState.showCaptchaDialog = false
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .glassEffect(.clear.tint(.white.opacity(0.5)), in: Capsule())

                    Button(appState.captchaChecking ? "稍等..." : "继续") {
                        Task { await appState.confirmCaptchaDialog() }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .glassEffect(.clear.tint(.white.opacity(0.5)), in: Capsule())
                    .disabled(appState.captchaChecking)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            // 液态玻璃（build 38 用 .regular，build 76 改 .clear：Russell 2026-11-19
            // 说 .regular 磨砂太重、模糊太高不喜欢，.clear 壁纸透出来、黑字照样可读）。
            // 卡片自己接住点击（contentShape + 空 onTapGesture，build 76）：
            // 点到卡片里的空白处不再漏到遮罩上关掉弹窗，只有真正点到卡片外面才关。
            // 之前点确认稍偏一点就关弹窗，就是因为卡片没接住点击。
            .glassEffect(.clear.tint(.white.opacity(0.5)), in: RoundedRectangle(cornerRadius: 26))
            .contentShape(RoundedRectangle(cornerRadius: 26))
            .onTapGesture { }
            .padding(.horizontal, 32)
        }
        .onAppear {
            captchaFocused = true
            cachedCaptchaImage = appState.captchaImageData.flatMap(UIImage.init(data:))
        }
        .onChange(of: appState.captchaImageData) { _, newData in
            cachedCaptchaImage = newData.flatMap(UIImage.init(data:))
                                                 }
    }

    private func refreshCaptcha() {
        guard !isRefreshingCaptcha else { return }
        isRefreshingCaptcha = true
        Task {
            await appState.fetchCaptcha()
            isRefreshingCaptcha = false
        }
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
        .glassEffect(.regular.tint(.white.opacity(0.25)), in: RoundedRectangle(cornerRadius: 25))
        // 原版提示条永远是浅色玻璃 + 深色字（哪怕在深色壁纸首页上也是）。
        // 玻璃材质只认窗口 trait，不认 .preferredColorScheme（build 33 实测：
        // 首页窗口是深色，光加 .preferredColorScheme(.light) 玻璃还是深灰，
        // 黑字就看不清了）。所以直接给玻璃加白 tint，强制白色玻璃，黑字可读。
        // 白 tint 别太高：0.75 像块不透光的白板，Russell 2026-11-18 13:09
        // 说不透明度太高看着难受；0.35 他 14:48 又说不够透，再降到 0.25。
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
