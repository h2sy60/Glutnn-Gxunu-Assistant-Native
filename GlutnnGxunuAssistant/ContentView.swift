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
        .glassEffect(.regular.tint(.white.opacity(0.35)), in: RoundedRectangle(cornerRadius: 25))
        // 原版提示条永远是浅色玻璃 + 深色字（哪怕在深色壁纸首页上也是）。
        // 玻璃材质只认窗口 trait，不认 .preferredColorScheme（build 33 实测：
        // 首页窗口是深色，光加 .preferredColorScheme(.light) 玻璃还是深灰，
        // 黑字就看不清了）。所以直接给玻璃加白 tint，强制白色玻璃，黑字可读。
        // 白 tint 别太高：0.75 像块不透光的白板，Russell 2026-11-18 13:09
        // 说不透明度太高看着难受；0.35 够透、还是浅色玻璃，黑字照样可读。
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
