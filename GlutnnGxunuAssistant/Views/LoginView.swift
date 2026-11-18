import SwiftUI
import UIKit // 仅用于把验证码图片 Data 解成 UIImage 再交给 SwiftUI Image 显示，不用 UIKit 搭界面。

// MARK: - 登录页（Flutter 版形态）：壁纸 + 44pt 学校名 + 玻璃输入框/玻璃按钮
//
// 学号/密码只发给当前学校的教务服务器。桂工每次登录都要验证码；
// 职师院默认不要，服务器要求时才亮验证码框。

struct LoginView: View {
    @Environment(AppState.self) private var appState

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
        NavigationStack {
            ZStack {
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // 学校名（44pt 白字 + 阴影，和 Flutter 登录页标题一致）
                        Text(appState.school.displayName)
                            .font(.system(size: 44, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                            .padding(.top, 60)

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
                                    appState.switchSchool(school)
                                    if school.captchaRequired {
                                        Task { await appState.fetchCaptcha() }
                                    }
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
                                            .frame(width: 160, height: 50)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .onTapGesture {
                                                Task { await appState.fetchCaptcha() }
                                            }
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.2))
                                            .frame(width: 160, height: 50)
                                            .overlay(Text("点我刷新").font(.caption).foregroundStyle(.white))
                                            .onTapGesture {
                                                Task { await appState.fetchCaptcha() }
                                            }
                                    }
                                    TextField("验证码", text: Binding(
                                        get: { appState.captchaText },
                                        set: { appState.captchaText = $0 }
                                    ))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.asciiCapable)
                                    .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }

                        // 登录按钮（全宽 52 高玻璃胶囊，“即刻登录”）
                        Button {
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
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationBarHidden(true)
        }
        .task {
            // 桂工默认要验证码，进页就取一张。
            if appState.school.captchaRequired && appState.captchaImageData == nil {
                await appState.fetchCaptcha()
            }
        }
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
