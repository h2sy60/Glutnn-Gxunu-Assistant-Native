import SwiftUI
import UIKit // 仅用于把验证码图片 Data 解成 UIImage 再交给 SwiftUI Image 显示，不用 UIKit 搭界面。

// MARK: - 登录页：选学校 + 学号 + 密码（+ 按需验证码）
//
// 学号/密码只发给当前学校的教务服务器。桂工每次登录都要验证码；
// 职师院默认不要，服务器要求时才亮验证码框。

struct LoginView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // 学校选择
                        Picker("学校", selection: Binding(
                            get: { appState.school.id },
                            set: { newId in
                                appState.switchSchool(schoolById(newId))
                                if appState.school.captchaRequired {
                                    Task { await appState.fetchCaptcha() }
                                }
                            }
                        )) {
                            ForEach(schools, id: \.id) { school in
                                Text(school.displayName).tag(school.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 24)

                        VStack(spacing: 16) {
                            // 学号
                            HStack(spacing: 12) {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                TextField("学号", text: Binding(
                                    get: { appState.studentId },
                                    set: { appState.studentId = $0 }
                                ))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                            // 密码
                            HStack(spacing: 12) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                SecureField("密码", text: Binding(
                                    get: { appState.password },
                                    set: { appState.password = $0 }
                                ))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                            // 验证码（桂工每次都要；职师院按需）
                            if appState.showCaptcha {
                                HStack(spacing: 12) {
                                    if let data = appState.captchaImageData,
                                       let uiImage = UIImage(data: data) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 100, height: 40)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .onTapGesture {
                                                Task { await appState.fetchCaptcha() }
                                            }
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(width: 100, height: 40)
                                            .overlay(Text("点我刷新").font(.caption).foregroundStyle(.secondary))
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
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }

                        // 登录按钮
                        Button {
                            Task { await appState.login() }
                        } label: {
                            if appState.loginLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Text("登录")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(appState.loginLoading)

                        // 错误提示
                        if let error = appState.loginError, !error.isEmpty {
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Text("学号和密码只发给 \(appState.school.displayName)教务服务器")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
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
