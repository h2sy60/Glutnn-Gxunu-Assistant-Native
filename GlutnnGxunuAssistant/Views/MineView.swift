import SwiftUI

/// 我的（Flutter 版形态）：壁纸 + 玻璃卡片。
struct MineView: View {
    @Environment(AppState.self) private var appState

    /// 玻璃卡片容器。
    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 顶栏：Hi! 名字（Flutter mine.dart 同款）
                        Text(appState.studentName.isEmpty ? "Hi!" : "Hi! \(appState.studentName)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                            .padding(.top, 60)
                            .padding(.horizontal, 20)

                        VStack(spacing: 12) {
                            // 个人信息卡片
                            glassCard {
                                HStack {
                                    Image(systemName: "person.circle.fill")
                                        .font(.largeTitle)
                                        .foregroundStyle(.white.opacity(0.9))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(appState.studentName.isEmpty ? "你好" : appState.studentName)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                        Text("\(appState.school.displayName) · \(appState.studentId)")
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    Spacer()
                                    Button("更换账号") {
                                        appState.switchAccount()
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .glassEffect(.regular, in: Capsule())
                                }
                            }

                            // 学期信息卡片
                            glassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("当前周")
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text("第 \(appState.currentWeek) 周")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    HStack {
                                        Text("学期")
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text("\(appState.year)-\(appState.year + 1) 学年 \(appState.semester)季学期")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                            }

                            // 成绩查询
                            NavigationLink(destination: ScoreView()) {
                                HStack {
                                    Image(systemName: "chart.bar.fill")
                                        .foregroundStyle(.white)
                                    Text("成绩查询")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                            }

                            // 课表设置（build 48，参考 WakeUp「课表外观」）
                            NavigationLink(destination: ScheduleSettingsView()) {
                                HStack {
                                    Image(systemName: "calendar.badge.clock")
                                        .foregroundStyle(.white)
                                    Text("课表设置")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                            }

                            // 关于（build 49）：作者信息、版本、检测更新、作者 GitHub
                            NavigationLink(destination: AboutView()) {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.white)
                                    Text("关于")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                            }

                            // 导出日志
                            glassCard {
                                HStack {
                                    ShareLink("导出日志", item: AppLogger.shared.exportText())
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text("遇到问题时导出日志，方便定位。")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }

                            // 退出登录
                            Button(role: .destructive) {
                                appState.logout()
                            } label: {
                                Text("退出登录")
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 14)
                            }
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 140)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }
}

#Preview {
    MineView()
        .environment(AppState())
}


#Preview {
    ScoreView()
        .environment(AppState())
}

// MARK: - 成绩页：列表 + 平均绩点/平均分（与 Flutter 版口径一致）

struct ScoreView: View {
    @Environment(AppState.self) private var appState

    /// 成绩数组存在 @State 里（普通值），.task 与 .onChange 再从 appState 同步。
    /// 注意：List 用 $scores（Binding）——本页的 List/ForEach 若传普通数组，
    /// Swift 6 会把它解析成 Binding 重载而报错（build 13–19 六次全挂）；
    /// 直接传 Binding 反而对上编译器要的重载，行内用 .wrappedValue 取值。
    @State private var scores: [CourseScore] = []

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if appState.scoresLoading && appState.scores.isEmpty {
                ProgressView("正在拉取成绩…")
            } else if let error = appState.scoresError, appState.scores.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") {
                        Task { await appState.refreshScores() }
                    }
                }
            } else if appState.scores.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无成绩")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("平均绩点")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f", gradePointAverage(scores)))
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("平均分")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f", averageScore(scores)))
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        Text("\(scores.count) 门课")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // 成绩列表（真实列表行，不及格标红，下拉刷新）。
                    List($scores, id: \.id) { $score in
                        let s = $score.wrappedValue
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.courseName)
                                    .font(.headline)
                                Text("\(s.teacher.isEmpty ? "—" : s.teacher) · \(s.courseCategory.isEmpty ? "—" : s.courseCategory)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("学分 \(s.credit, specifier: "%.1f") · 绩点 \(s.gradePoint, specifier: "%.2f")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(s.rawScore)
                                .font(.headline)
                                .foregroundStyle(s.score < 60 && s.score > 0 ? .red : .primary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await appState.refreshScores()
                    }
                }
            }
        }
        .navigationTitle("成绩")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.scores.isEmpty && appState.scoresError == nil {
                await appState.refreshScores()
            }
            scores = appState.scores
        }
        .onChange(of: appState.scores.count) { _, _ in
            scores = appState.scores
        }
    }
}

/// 考试安排页（build 43 新增）。与 ScoreView 同款结构：
/// List 用 $exams（Binding），避免 Swift 6 把普通数组解析成 Binding 重载。
struct ExamsView: View {
    @Environment(AppState.self) private var appState

    @State private var exams: [ExamItem] = []

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if appState.examsLoading && appState.exams.isEmpty {
                ProgressView("正在拉取考试安排…")
            } else if let error = appState.examsError, appState.exams.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") {
                        Task { await appState.refreshExams() }
                    }
                }
            } else if appState.exams.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无考试安排")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                List($exams, id: \.id) { $exam in
                    let e = $exam.wrappedValue
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.courseName)
                            .font(.headline)
                        if !e.examName.isEmpty {
                            Text(e.examName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(e.time)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(e.location)
                            if !e.seatNumber.isEmpty {
                                Text("· 座位 \(e.seatNumber)")
                            }
                            if !e.campus.isEmpty {
                                Text("· \(e.campus)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await appState.refreshExams()
                }
            }
        }
        .navigationTitle("考试")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.exams.isEmpty && appState.examsError == nil {
                await appState.refreshExams()
            }
            exams = appState.exams
        }
        .onChange(of: appState.exams.count) { _, _ in
            exams = appState.exams
        }
    }
}

// MARK: - 关于页（build 49）：作者信息、版本、检测更新、作者 GitHub
//
// “我的”页 → 关于：显示作者（Russell / h2sy60，点按跳作者 GitHub
// 主页）、当前版本、检测更新（查 GitHub 最新 Release，比对版本号，
// 有新版弹提示去下载，没有就提示已是最新）。

struct AboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    /// 是否正在检测更新（转圈 + 禁点）。
    @State private var checkingUpdate = false
    /// 是否弹出“发现新版本”提示。
    @State private var showUpdateAlert = false
    /// 检测到的最新版本号（去掉 v 前缀，如 1.0.1）。
    @State private var latestVersion = ""
    /// 检测到的最新 Release 页面。
    @State private var latestReleaseURL: URL?

    /// 当前版本（Info.plist CFBundleShortVersionString）：如 1.0.0。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    /// 当前构建号（Info.plist CFBundleVersion）：如 49。
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// 作者 GitHub 主页。
    private static let authorGitHubURL = URL(string: "https://github.com/h2sy60")!
    /// 仓库 Releases 页（检测更新没取到 html_url 时的兜底）。
    private static let releasesURL = URL(string: "https://github.com/h2sy60/Glutnn-Gxunu-Assistant-Native/releases")!

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            List {
                Section {
                    // 应用名 + 版本
                    HStack {
                        Image(systemName: "graduationcap.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("桂工课程助手")
                            Text("版本 \(appVersion) (build \(appBuild))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 作者：点按跳作者 GitHub 主页
                    Button {
                        openURL(Self.authorGitHubURL)
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Russell")
                                Text("作者 · h2sy60")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    // 检测更新
                    Button {
                        Task { await checkForUpdate() }
                    } label: {
                        HStack {
                            Text("检测更新")
                            Spacer()
                            if checkingUpdate {
                                ProgressView()
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(checkingUpdate)
                } footer: {
                    Text("新版本发布在 GitHub Releases；检测到新版本后会提示下载。")
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .alert("发现新版本 \(latestVersion)", isPresented: $showUpdateAlert) {
            Button("去下载") {
                openURL(latestReleaseURL ?? Self.releasesURL)
            }
            Button("稍后", role: .cancel) { }
        } message: {
            Text("当前版本 \(appVersion)，去 GitHub 下载最新版。")
        }
    }

    /// 检测更新：GET GitHub 最新 Release，比对 tag 与当前版本。
    private func checkForUpdate() async {
        checkingUpdate = true
        defer { checkingUpdate = false }
        guard let url = URL(string: "https://api.github.com/repos/h2sy60/Glutnn-Gxunu-Assistant-Native/releases/latest") else {
            appState.showToast(.error, "检查更新失败，请稍后重试", duration: 3)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                appState.showToast(.error, "检查更新失败，请稍后重试", duration: 3)
                return
            }
            // 还没发过 Release（404）：没有可更新的版本，当作已是最新。
            if http.statusCode == 404 {
                appState.showToast(.success, "已是最新版本", duration: 2)
                return
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                appState.showToast(.error, "检查更新失败，请稍后重试", duration: 3)
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if isNewerVersion(latest, than: appVersion) {
                latestVersion = latest
                if let html = json["html_url"] as? String, let releaseURL = URL(string: html) {
                    latestReleaseURL = releaseURL
                } else {
                    latestReleaseURL = Self.releasesURL
                }
                showUpdateAlert = true
            } else {
                appState.showToast(.success, "已是最新版本", duration: 2)
            }
        } catch {
            appState.showToast(.error, "检查更新失败，请稍后重试", duration: 3)
        }
    }

    /// 语义版本比较：latest 是否比 current 新（按 . 分段逐段比数字）。
    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let l = latest.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}
