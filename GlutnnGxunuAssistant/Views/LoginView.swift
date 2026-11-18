import SwiftUI
import UIKit // 仅用于把验证码图片 Data 解成 UIImage 再交给 SwiftUI Image 显示，不用 UIKit 搭界面。

// MARK: - 登录页（Flutter 版形态）：壁纸 + 44pt 学校名 + 玻璃输入框/玻璃按钮
//
// 学号/密码只发给当前学校的教务服务器。桂工每次登录都要验证码；
// 职师院默认不要，服务器要求时才亮验证码框。

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// 焦点字段：点空白处收键盘时用（build 42）。
    private enum Field: Hashable {
        case studentId, password, captcha
    }
    @FocusState private var focusedField: Field?

    /// 玻璃输入框容器（图标 + 内容），和 Flutter 的玻璃框一个意思。
    private func glassField<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        // 键盘不动方案（build 42，专家三）：删 NavigationStack（它在
        // fullScreenCover 里劫持安全区），GeometryReader + .ignoresSafeArea(.keyboard)
        // 锁高——VStack 高度定死为 geo.size.height，键盘弹起时 geo.size 不变，
        // 内容钉在顶部不动。之前四轮全败的原因：VStack 总高（~579pt，桂工多
        // 验证码行）超过键盘上方剩余高度（~516pt），系统强行把整页往上顶约 60pt。
        // 顶部只留 16pt：没有 ignoresSafeArea(.top)，内容自动在状态栏下方。
        GeometryReader { geo in
            ZStack(alignment: .top) {
                WallpaperBackground()
                    .ignoresSafeArea()
                    .onTapGesture {
                        focusedField = nil
                    }

                VStack(spacing: 20) {
                    // 学校名（44pt 白字 + 阴影）+ 右上角关闭钮（旧版登录页同款：点 X 回首页，不用登录也能看）。
                    HStack(alignment: .center) {
                        Text(appState.school.displayName)
                            .font(.system(size: 44, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                        Spacer()
                        Button {
                            focusedField = nil
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                    }
                    .padding(.top, 16)

                    // 状态提示行（登录失败/提示文案，白字 + 阴影）
                    if let error = appState.loginError, !error.isEmpty {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
                            .multilineTextAlignment(.center)
                    }

                    // 学校选择（自绘分段：选中 = 白底黑字加粗，未选中 = 透明底白字）
                    HStack(spacing: 0) {
                        ForEach(schools, id: \.id) { school in
                            Button {
                                // 先收焦点，再原子化切换学校（验证码由 switchSchool
                                // 内部统一拉取，按钮里不再另起 Task）。
                                focusedField = nil
                                appState.switchSchool(school)
                            } label: {
                                Text(school.displayName)
                                    .font(.system(size: 15, weight: appState.school.id == school.id ? .bold : .regular))
                                    .foregroundStyle(appState.school.id == school.id ? .black : .white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .background(
                                appState.school.id == school.id ? Color.white : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                    }
                    .padding(4)
                    .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))

                    VStack(spacing: 16) {
                        // 学号（桂工数字键盘，职师院全键盘）
                        glassField(icon: "person.fill") {
                            TextField("学号", text: Binding(
                                get: { appState.studentId },
                                set: { appState.studentId = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(appState.school.id == .gut ? .numberPad : .asciiCapable)
                            .focused($focusedField, equals: .studentId)
                            .foregroundStyle(.white)
                        }

                        // 密码
                        glassField(icon: "lock.fill") {
                            SecureField("密码", text: Binding(
                                get: { appState.password },
                                set: { appState.password = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .password)
                            .onSubmit {
                                Task { await appState.login() }
                            }
                            .foregroundStyle(.white)
                        }

                        // 验证码（桂工每次都要；职师院按需）
                        if appState.showCaptcha {
                            HStack(spacing: 12) {
                                if let data = appState.captchaImageData,
                                   let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 80, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture {
                                            appState.requestCaptcha()
                                        }
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.2))
                                        .frame(width: 80, height: 28)
                                        .overlay(Text("点我刷新").font(.caption).foregroundStyle(.white))
                                        .onTapGesture {
                                            appState.requestCaptcha()
                                        }
                                }
                                TextField("验证码", text: Binding(
                                    get: { appState.captchaText },
                                    set: { appState.captchaText = $0 }
                                ))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                                .focused($focusedField, equals: .captcha)
                                .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    // 登录按钮（全宽 52 高玻璃胶囊，“即刻登录”）
                    Button {
                        focusedField = nil
                        Task { await appState.login() }
                    } label: {
                        if appState.loginLoading {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        } else {
                            Text("即刻登录")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                    }
                    .glassEffect(.regular, in: Capsule())
                    .disabled(appState.loginLoading)

                    Text("学号和密码只发给 \(appState.school.displayName)教务服务器")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                // 高度定死为 geo.size.height：键盘弹起时 geo.size 不变，
                // 内容钉在顶部，键盘只从底部盖上来。
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        // 在 GeometryReader 外层忽略键盘安全区，确保 geo.size.height 永远不变。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task {
            // 桂工默认要验证码，进页就取一张。
            if appState.school.captchaRequired && appState.captchaImageData == nil {
                appState.requestCaptcha()
            }
        }
        .onChange(of: appState.isLoggedIn) { _, loggedIn in
            // 登录成功就关掉本页回首页（旧版登录成功后 pushAndRemoveUntil 回 Layout）。
            if loggedIn {
                focusedField = nil
                dismiss()
            }
        }
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
