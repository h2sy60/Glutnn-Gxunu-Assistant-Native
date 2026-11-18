import SwiftUI
import UIKit // 仅用于把学生照片 Data 解成 UIImage 再交给 SwiftUI Image 显示。
import PDFKit // 培养方案 PDF 展示（build 53）。

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

    /// build 53：学年/学期筛选。selectedYear nil = 全部学年；
    /// selectedTermIndex 0 = 全部学期，1 = 第一学期，2 = 第二学期。
    @State private var selectedYear: Int? = nil
    @State private var selectedTermIndex: Int = 0

    /// 可选学年：从入学年（2026）到当前年。
    private var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        let startYear = 2026
        guard currentYear >= startYear else { return [startYear] }
        return Array(startYear...currentYear)
    }

    /// 学期码：职师院第一学期 3、第二学期 12；
    /// 桂工秋 3、春 1（build 58 按旧项目：秋=3、春=1；之前暂定的 1、2 是错的）。
    private var termCode: String? {
        guard selectedTermIndex != 0 else { return nil }
        if appState.school.id == .gut {
            return selectedTermIndex == 1 ? "3" : "1"
        }
        return selectedTermIndex == 1 ? "3" : "12"
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 筛选行（始终可见，空状态下也能改筛选）。
                HStack(spacing: 12) {
                    Picker("学年", selection: $selectedYear) {
                        Text("全部学年").tag(nil as Int?)
                        ForEach(availableYears, id: \.self) { y in
                            Text("\(y)-\(y + 1)").tag(y as Int?)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("学期", selection: $selectedTermIndex) {
                        Text("全部学期").tag(0)
                        Text("第一学期").tag(1)
                        Text("第二学期").tag(2)
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if appState.scoresLoading && appState.scores.isEmpty {
                    Spacer()
                    ProgressView("正在拉取成绩…")
                    Spacer()
                } else if let error = appState.scoresError, appState.scores.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("重新拉取") {
                            Task { await appState.refreshScores(year: selectedYear, term: termCode) }
                        }
                    }
                    Spacer()
                } else if appState.scores.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "list.clipboard")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("暂无成绩")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                            await appState.refreshScores(year: selectedYear, term: termCode)
                        }
                    }
                }
            }
        }
        .navigationTitle("成绩")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.scores.isEmpty && appState.scoresError == nil {
                await appState.refreshScores(year: selectedYear, term: termCode)
            }
            scores = appState.scores
        }
        .onChange(of: appState.scores.count) { _, _ in
            scores = appState.scores
        }
        .onChange(of: selectedYear) { _, _ in
            Task { await appState.refreshScores(year: selectedYear, term: termCode) }
        }
        .onChange(of: selectedTermIndex) { _, _ in
            Task { await appState.refreshScores(year: selectedYear, term: termCode) }
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
                        HStack(spacing: 6) {
                            Text(e.courseName)
                                .font(.headline)
                            // build 58：旧项目按结束时间算已考/待考，已考的打个标记。
                            if e.isPast {
                                Text("已考")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                            Text("周周有善")
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

// MARK: - 更多（build 50，职师院专属）：HAR 抓包确认值得做的功能入口
//
// 首页第二行「更多」→ 本页：学分、教学执行计划、学生评教、待办事项、
// 个人信息、学籍预警。全部只读（评教的打分仍需在教务网页完成）。
// 桂工没有对应接口，本页只在职师院显示（首页第二行已按学校隐藏）。

struct GXVNUMoreView: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            List {
                Section("学习") {
                    NavigationLink(destination: GXVNUGraduationView()) {
                        moreRowContent(icon: "chart.bar.fill", title: "毕业进度", subtitle: "总要求与已修得、在修、还差")
                    }
                    NavigationLink(destination: GXVNUCreditsView()) {
                        moreRowContent(icon: "creditcard.fill", title: "学分", subtitle: "已选课程与总学分")
                    }
                    NavigationLink(destination: GXVNUTeachingPlanView()) {
                        moreRowContent(icon: "book.fill", title: "教学执行计划", subtitle: "本学院各专业培养方案概览")
                    }
                    NavigationLink(destination: GXVNUTrainingPlanView()) {
                        moreRowContent(icon: "doc.fill", title: "培养方案", subtitle: "官方培养方案 PDF")
                    }
                    NavigationLink(destination: GXVNUEvaluationsView()) {
                        moreRowContent(icon: "star.fill", title: "学生评教", subtitle: "待评课程与提交情况")
                    }
                    NavigationLink(destination: GXVNUThesisView()) {
                        moreRowContent(icon: "graduationcap.fill", title: "毕设", subtitle: "已选题数与选题列表")
                    }
                }
                Section("通知与学籍") {
                    NavigationLink(destination: GXVNUToDosView()) {
                        moreRowContent(icon: "bell.fill", title: "待办事项", subtitle: "调课、补课等提醒")
                    }
                    NavigationLink(destination: GXVNUNotificationsView()) {
                        moreRowContent(icon: "megaphone.fill", title: "通知公告", subtitle: "学校通知")
                    }
                    NavigationLink(destination: GXVNUProfileView()) {
                        moreRowContent(icon: "person.fill", title: "个人信息", subtitle: "学院、专业、班级与照片")
                    }
                    NavigationLink(destination: GXVNUWarningView()) {
                        moreRowContent(icon: "exclamationmark.triangle.fill", title: "学籍预警", subtitle: "风险课程与预警学分")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func moreRowContent(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 桂工更多（build 58，按旧项目 Mine 页：教学计划 + 教室查询）

/// 桂工“更多”：教学计划、空教室查询（旧项目 Mine 页就这两项）。
struct GUTMoreView: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            List {
                Section("查询") {
                    NavigationLink(destination: GUTTeachingPlanView()) {
                        gutMoreRowContent(icon: "book.fill", title: "教学计划", subtitle: "按学期分的全部课程")
                    }
                    NavigationLink(destination: GUTClassroomQueryView()) {
                        gutMoreRowContent(icon: "building.2.fill", title: "空教室查询", subtitle: "按教学楼、周次、星期查空教室")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gutMoreRowContent(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 桂工教学计划（build 58，按旧项目 teachingPlanPage）

struct GUTTeachingPlanView: View {
    @State private var plan: GUTTeachingPlan?
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && plan == nil {
                ProgressView("正在拉取教学计划…")
            } else if let errorMessage, plan == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if let plan {
                List {
                    Section("基本信息") {
                        LabeledContent("院系", value: plan.department.isEmpty ? "—" : plan.department)
                        LabeledContent("专业", value: plan.major.isEmpty ? "—" : plan.major)
                        LabeledContent("年级", value: plan.grade == 0 ? "—" : "\(plan.grade)级")
                        LabeledContent("层次", value: plan.educationalLevel.isEmpty ? "—" : plan.educationalLevel)
                        LabeledContent("学制", value: "\(plan.schoolingLength)年")
                        LabeledContent("课程总数", value: "\(plan.totalCourseCount)门")
                        LabeledContent("考试课", value: "\(plan.totalExamCount)门")
                        LabeledContent("专业课", value: "\(plan.totalMajorCourseCount)门")
                        LabeledContent("已通过", value: "\(plan.passCount)门")
                        LabeledContent("未通过", value: "\(plan.failCount)门")
                    }
                    ForEach(Array(plan.semesters.enumerated()), id: \.offset) { index, courses in
                        // 旧项目按秋/春分：单数学期是秋，双数学期是春。
                        Section("第\(index + 1)学期 · \(index % 2 == 0 ? "秋" : "春")") {
                            ForEach(courses) { course in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(course.name)
                                        .font(.headline)
                                    HStack(spacing: 8) {
                                        Text(course.code)
                                        Text(course.assessmentType)
                                        Text("\(course.credit)学分")
                                        Text("\(course.hours)学时")
                                        Text(course.category)
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "book")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无教学计划")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("教学计划")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            plan = try await GUTService.fetchTeachingPlan()
            errorMessage = nil
        } catch let error as ScheduleError {
            errorMessage = error == .sessionExpired ? "登录已过期，请重新登录" : error.errorDescription
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取教学计划失败"
        }
    }
}

// MARK: - 桂工空教室查询（build 58，按旧项目 classroomQueryPage）

struct GUTClassroomQueryView: View {
    @Environment(AppState.self) private var appState

    @State private var buildings: [GUTClassroomBuilding] = []
    @State private var selectedBuildingId: String = "-1"
    @State private var selectedWeek: Int = 1
    @State private var selectedDay: Int = 1
    @State private var rooms: [GUTClassroom] = []
    @State private var isLoadingOptions = false
    @State private var isQuerying = false
    @State private var errorMessage: String? = nil
    @State private var hasQueried = false

    private var weekOptions: [Int] { Array(1...20) }
    private var dayNames: [String] { ["周一", "周二", "周三", "周四", "周五", "周六", "周日"] }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            List {
                Section("查询条件") {
                    Picker("教学楼", selection: $selectedBuildingId) {
                        Text("请选择").tag("-1")
                        ForEach(buildings) { b in
                            Text(b.name).tag(b.buildingId)
                        }
                    }
                    Picker("周次", selection: $selectedWeek) {
                        ForEach(weekOptions, id: \.self) { w in
                            Text("第\(w)周").tag(w)
                        }
                    }
                    Picker("星期", selection: $selectedDay) {
                        ForEach(1...7, id: \.self) { d in
                            Text(dayNames[d - 1]).tag(d)
                        }
                    }
                    Button("即刻查询") {
                        Task { await query() }
                    }
                    .disabled(selectedBuildingId == "-1" || isQuerying)
                }
                if isQuerying && rooms.isEmpty {
                    Section {
                        HStack { Spacer(); ProgressView("查询中…"); Spacer() }
                    }
                } else if let errorMessage, rooms.isEmpty, hasQueried {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if hasQueried && rooms.isEmpty {
                    Section {
                        Text("该教学楼本周没有空教室")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if !rooms.isEmpty {
                    Section("空教室（\(rooms.count)间）") {
                        ForEach(rooms) { room in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(room.roomNumber)
                                        .font(.headline)
                                    Text(room.type)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if room.isAllDayFree {
                                        Text("全天空闲")
                                            .font(.subheadline)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text("座位 \(room.seatCount) · 考试座位 \(room.examSeatCount)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if !room.isAllDayFree {
                                    Text(freeSectionsText(room.occupancy))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("空教室查询")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 默认本周、本星期（旧项目：周次取当前周，星期取今天）。
            selectedWeek = appState.currentWeek
            let swiftWeekday = Calendar.current.component(.weekday, from: Date())
            selectedDay = swiftWeekday == 1 ? 7 : swiftWeekday - 1
            await loadBuildings()
        }
    }

    /// 空闲节次文案（旧项目 promptMessage：全天空闲 / 第 X 节有课 / 全天满课）。
    private func freeSectionsText(_ occupancy: [Bool]) -> String {
        let busy = occupancy.enumerated().filter { !$0.element }.map { $0.offset + 1 }
        if busy.isEmpty { return "全天空闲" }
        if busy.count == occupancy.count { return "全天满课" }
        return "有课：第 " + busy.map(String.init).joined(separator: "、") + " 节"
    }

    private func loadBuildings() async {
        guard !isLoadingOptions else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            buildings = try await GUTService.fetchClassroomBuildings()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取教学楼失败"
        }
    }

    private func query() async {
        guard selectedBuildingId != "-1", !isQuerying else { return }
        isQuerying = true
        hasQueried = true
        errorMessage = nil
        defer { isQuerying = false }
        do {
            rooms = try await GUTService.fetchFreeClassrooms(
                building: selectedBuildingId,
                week: String(selectedWeek),
                dayOfWeek: String(selectedDay)
            )
        } catch let error as ScheduleError {
            errorMessage = error == .sessionExpired ? "登录已过期，请重新登录" : error.errorDescription
            rooms = []
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "查询失败"
            rooms = []
        }
    }
}

// MARK: - 待办事项（build 50）：调课/补课提醒（index_cxDbsy）

struct GXVNUToDosView: View {
    @State private var todos: [GXVNUTodoItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && todos.isEmpty {
                ProgressView("正在拉取待办事项…")
            } else if let errorMessage, todos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if todos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无待办事项")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                List($todos, id: \.id) { $todo in
                    let t = $todo.wrappedValue
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if !t.isRead {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 8, height: 8)
                            }
                            Text(t.title)
                                .font(.headline)
                                .fontWeight(t.isRead ? .regular : .bold)
                        }
                        if !t.time.isEmpty {
                            Text(t.time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !t.content.isEmpty {
                            Text(t.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("待办事项")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            todos = try await GXVNUService.fetchTodos()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 学生评教（build 50）：待评列表 + 统计（xspj，全部只读）
//
// 打分表单是 HTML（xspj_cxXspjDisplay），本版只做只读列表与统计；
// 真正打分请在教务系统网页完成（页底有提示）。

struct GXVNUEvaluationsView: View {
    @State private var evaluations: [GXVNUEvaluationItem] = []
    @State private var stats: GXVNUEvaluationStats? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && evaluations.isEmpty {
                ProgressView("正在拉取评教信息…")
            } else if let errorMessage, evaluations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if evaluations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "star")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无待评教课程")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    if let stats {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("待评")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(stats.pending) 门")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundStyle(stats.pending > 0 ? .orange : .primary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已提交")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(stats.submitted) 门")
                                    .font(.title3)
                                    .fontWeight(.bold)
                            }
                            Spacer()
                            Text("共 \(stats.total) 门")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }

                    List($evaluations, id: \.id) { $evaluation in
                        let e = $evaluation.wrappedValue
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(e.courseName)
                                    .font(.headline)
                                Spacer()
                                Text(e.isPending ? "待评" : (e.statusText.isEmpty ? "已评" : e.statusText))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(e.isPending ? .orange : .green)
                            }
                            Text("\(e.teacher.isEmpty ? "—" : e.teacher)\(e.className.isEmpty ? "" : " · \(e.className)")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !e.location.isEmpty || !e.time.isEmpty {
                                Text("\(e.location)\(e.location.isEmpty || e.time.isEmpty ? "" : " · ")\(e.time)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await load() }

                    Text("评教打分请在教务系统网页完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("学生评教")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedStats = GXVNUService.fetchEvaluationStats()
            async let fetchedList = GXVNUService.fetchEvaluations()
            let (s, list) = try await (fetchedStats, fetchedList)
            stats = s
            evaluations = list
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 学分（build 50）：已选课程与总学分（xsxxwh_cxXsxkxx）

struct GXVNUCreditsView: View {
    @State private var courses: [GXVNUSelectedCourse] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    /// 已选总学分。
    private var totalCredits: Double {
        courses.reduce(0) { $0 + $1.credit }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && courses.isEmpty {
                ProgressView("正在拉取选课信息…")
            } else if let errorMessage, courses.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if courses.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无选课信息")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已选总学分")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f", totalCredits))
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        Text("\(courses.count) 门课")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    List($courses, id: \.id) { $course in
                        let c = $course.wrappedValue
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.courseName)
                                    .font(.headline)
                                Spacer()
                                Text("\(c.credit, specifier: "%.1f") 学分")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            Text("\(c.teacher.isEmpty ? "—" : c.teacher)\(c.category.isEmpty ? "" : " · \(c.category)")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !c.location.isEmpty || !c.time.isEmpty {
                                Text("\(c.location)\(c.location.isEmpty || c.time.isEmpty ? "" : " · ")\(c.time)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await load() }
                }
            }
        }
        .navigationTitle("学分")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            courses = try await GXVNUService.fetchSelectedCourses()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 教学执行计划（build 50）：本学院各专业培养方案概览（jxzxjhck）
//
// 先 resolveAcademicIDs（个人信息页 + 专业下拉）取学院/年级代码，
// 再按学院 + 年级拉计划列表；本专业打“本专业”标记。

struct GXVNUTeachingPlanView: View {
    @State private var plans: [GXVNUTeachingPlan] = []
    @State private var myMajor: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && plans.isEmpty {
                ProgressView("正在拉取教学执行计划…")
            } else if let errorMessage, plans.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if plans.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无教学执行计划")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                List($plans, id: \.id) { $plan in
                    let p = $plan.wrappedValue
                    let isMine = !myMajor.isEmpty && p.majorName == myMajor
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.majorName)
                                .font(.headline)
                            if isMine {
                                Text("本专业")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("\(p.gradeName.isEmpty ? "" : "\(p.gradeName) · ")\(p.campus)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(p.courseCount) 门课 · \(p.hours) 学时 · 总学分 \(p.totalCredits)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("教学执行计划")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = try await GXVNUService.resolveAcademicIDs()
            myMajor = ids.major
            plans = try await GXVNUService.fetchTeachingPlan(ids: ids)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 个人信息（build 50）：学院/专业/班级/照片（xsgrxxwh + 照片）
//
// 个人信息取自个人信息页 HTML（服务端直出文本）；照片先取首页用户信息
// 拿到 xh_id 再拉 JPEG。照片拉不到只显示占位头像，不影响信息展示。

struct GXVNUProfileView: View {
    @Environment(AppState.self) private var appState

    @State private var profile: GXVNUProfile? = nil
    @State private var photoData: Data? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && profile == nil {
                ProgressView("正在拉取个人信息…")
            } else if let errorMessage, profile == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if let profile {
                List {
                    Section {
                        HStack(spacing: 16) {
                            if let photoData, let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 72))
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appState.studentName.isEmpty ? "你好" : appState.studentName)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                Text(appState.school.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if !appState.studentId.isEmpty {
                                    Text(appState.studentId)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("学籍") {
                        profileRow(label: "年级", value: profile.grade)
                        profileRow(label: "学院", value: profile.college)
                        profileRow(label: "专业", value: profile.major)
                        profileRow(label: "班级", value: profile.className)
                        profileRow(label: "学制", value: profile.duration.isEmpty ? "" : "\(profile.duration) 年")
                        profileRow(label: "学籍状态", value: profile.status)
                        profileRow(label: "报到注册", value: profile.enrollStatus)
                        profileRow(label: "培养层次", value: profile.level)
                        profileRow(label: "学生类别", value: profile.category)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("个人信息")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func profileRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await GXVNUService.fetchProfile()
            errorMessage = nil
            // 照片单独拉，失败不影响信息展示。
            if let data = try? await GXVNUService.fetchProfilePhoto() {
                photoData = data
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 学籍预警（build 50）：风险课程与预警学分（xjyj）
//
// 空列表 = 没有预警（好事），显示绿色对勾而不是“暂无数据”。

struct GXVNUWarningView: View {
    @State private var warnings: [GXVNUWarning] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && warnings.isEmpty {
                ProgressView("正在拉取学籍预警…")
            } else if let errorMessage, warnings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if warnings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("暂无学籍预警")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("没有风险课程，继续保持")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                List($warnings, id: \.id) { $warning in
                    let w = $warning.wrappedValue
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(w.term.isEmpty ? "学籍预警" : w.term)
                                .font(.headline)
                            Spacer()
                            if !w.warningCredits.isEmpty {
                                Text("预警学分 \(w.warningCredits)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("风险课程")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(w.courses, id: \.self) { course in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(course)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("学籍预警")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = try await GXVNUService.resolveAcademicIDs()
            warnings = try await GXVNUService.fetchAcademicWarning(ids: ids)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 毕业进度（build 53）：总要求 + 已修得/在修/还差 + 按课程性质拆分
//
// 数据：教学计划头 zdxf（总学分）+ 计划课程明细（按 KCXZMC 分类的要求学分）
// + 已选课程（在修）+ 成绩（已修得，score >= 60 计为通过）。
// 大一新生：已修得 0、在修 25.2、总要求 75。

struct GXVNUGraduationView: View {
    @State private var totalCredits: Double = 0
    @State private var earnedCredits: Double = 0
    @State private var inProgressCredits: Double = 0
    @State private var breakdown: [GraduationCategoryRow] = []
    @State private var majorName: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    /// 按课程性质汇总的一行。
    struct GraduationCategoryRow: Identifiable {
        let id = UUID()
        var category: String
        var required: Double
        var earned: Double
        var inProgress: Double
    }

    private var remainingCredits: Double {
        max(totalCredits - earnedCredits - inProgressCredits, 0)
    }

    private var progress: Double {
        guard totalCredits > 0 else { return 0 }
        return min((earnedCredits + inProgressCredits) / totalCredits, 1)
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && breakdown.isEmpty && totalCredits == 0 {
                ProgressView("正在拉取毕业进度…")
            } else if let errorMessage, breakdown.isEmpty && totalCredits == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            if !majorName.isEmpty {
                                Text(majorName)
                                    .font(.headline)
                            }
                            HStack(spacing: 0) {
                                summaryCell(title: "总要求", value: totalCredits, unit: "学分")
                                Divider().frame(height: 36).padding(.horizontal, 12)
                                summaryCell(title: "已修得", value: earnedCredits, unit: "学分")
                                Divider().frame(height: 36).padding(.horizontal, 12)
                                summaryCell(title: "在修", value: inProgressCredits, unit: "学分")
                                Divider().frame(height: 36).padding(.horizontal, 12)
                                summaryCell(title: "还差", value: remainingCredits, unit: "学分")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("毕业进度")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(progress * 100))%")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .tint(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("按课程性质") {
                        ForEach(breakdown) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.category.isEmpty ? "未分类" : row.category)
                                        .font(.headline)
                                    Spacer()
                                    Text("要求 \(row.required, specifier: "%.1f")")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 16) {
                                    Text("已修得 \(row.earned, specifier: "%.1f")")
                                        .font(.subheadline)
                                        .foregroundStyle(row.earned > 0 ? .green : .secondary)
                                    Text("在修 \(row.inProgress, specifier: "%.1f")")
                                        .font(.subheadline)
                                        .foregroundStyle(row.inProgress > 0 ? .blue : .secondary)
                                    Spacer()
                                    Text("还差 \(max(row.required - row.earned - row.inProgress, 0), specifier: "%.1f")")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: row.required > 0 ? min((row.earned + row.inProgress) / row.required, 1) : 0)
                                    .progressViewStyle(.linear)
                                    .tint(.green)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("毕业进度")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func summaryCell(title: String, value: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", value))
                    .font(.title3)
                    .fontWeight(.bold)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = try await GXVNUService.resolveAcademicIDs()
            let plans = try await GXVNUService.fetchTeachingPlan(ids: ids)
            // 本专业计划：专业名与个人信息里的专业一致（与教学计划页同款匹配）。
            let myPlan = plans.first { $0.majorName == ids.major }
                ?? plans.first { !$0.majorName.isEmpty && ids.major.contains($0.majorName) }
                ?? plans.first { !$0.majorName.isEmpty && $0.majorName.contains(ids.major) }
                ?? plans.first
            guard let plan = myPlan else {
                errorMessage = "未找到本专业教学计划"
                return
            }
            majorName = plan.majorName
            totalCredits = Double(plan.totalCredits) ?? 0
            // 计划课程明细（按性质汇总要求学分）。
            var requiredByCategory: [String: Double] = [:]
            if !plan.planId.isEmpty {
                let planCourses = try await GXVNUService.fetchPlanCourses(planId: plan.planId)
                for c in planCourses {
                    requiredByCategory[c.category, default: 0] += c.credit
                }
            }
            // 在修（已选课程）。
            let selected = try await GXVNUService.fetchSelectedCourses()
            inProgressCredits = selected.reduce(0) { $0 + $1.credit }
            var inProgressByCategory: [String: Double] = [:]
            for c in selected {
                inProgressByCategory[c.category, default: 0] += c.credit
            }
            // 已修得（成绩，score >= 60 计为通过）。
            let scores = try await GXVNUService.fetchScores(year: nil, term: nil)
            var earnedByCategory: [String: Double] = [:]
            var earned: Double = 0
            for s in scores where s.score >= 60 {
                earned += s.credit
                earnedByCategory[s.courseCategory, default: 0] += s.credit
            }
            earnedCredits = earned
            // 合并所有性质，按要求学分从大到小排。
            let allCategories = Set(requiredByCategory.keys)
                .union(inProgressByCategory.keys)
                .union(earnedByCategory.keys)
            breakdown = allCategories.map { cat in
                GraduationCategoryRow(
                    category: cat,
                    required: requiredByCategory[cat] ?? 0,
                    earned: earnedByCategory[cat] ?? 0,
                    inProgress: inProgressByCategory[cat] ?? 0
                )
            }.sorted { $0.required > $1.required }
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 通知公告（build 53）：index_cxNews HTML 解析，只读列表 + 详情

struct GXVNUNotificationsView: View {
    @State private var items: [GXVNUNotification] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && items.isEmpty {
                ProgressView("正在拉取通知公告…")
            } else if let errorMessage, items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "megaphone")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无通知公告")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                List($items, id: \.id) { $item in
                    let n = $item.wrappedValue
                    NavigationLink(destination: GXVNUNotificationDetailView(xwbh: n.xwbh, title: n.title)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(n.date)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("通知公告")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await GXVNUService.fetchNotifications()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

/// 通知详情：拉 xwck_ckXw.html，去标签后显示纯文本。
struct GXVNUNotificationDetailView: View {
    var xwbh: String
    var title: String
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && content.isEmpty {
                ProgressView("正在拉取详情…")
            } else if let errorMessage, content.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else {
                ScrollView {
                    Text(content.isEmpty ? "内容为空" : content)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await GXVNUService.fetchNotificationDetail(xwbh: xwbh)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}

// MARK: - 培养方案 PDF（build 53）：pyfaxxck_dyPyfaxx.html，PDFKit 展示

struct GXVNUTrainingPlanView: View {
    @State private var pdfData: Data? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && pdfData == nil {
                ProgressView("正在下载培养方案…")
            } else if let errorMessage, pdfData == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新下载") { Task { await load() } }
                }
            } else if let pdfData {
                PDFKitView(data: pdfData)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无培养方案")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("培养方案")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            pdfData = try await GXVNUService.fetchTrainingPlanPDF()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "下载失败，请稍后重试"
        }
    }
}

/// PDFKit 的 PDFView 包装（UIViewRepresentable），用于培养方案展示。
struct PDFKitView: UIViewRepresentable {
    var data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil, let document = PDFDocument(data: data) {
            view.document = document
        }
    }
}

// MARK: - 毕设（build 53）：已选题数 + 选题列表（大一为空，大四才有数据）

struct GXVNUThesisView: View {
    @State private var selectedCount: Int = 0
    @State private var topics: [GXVNUThesisTopic] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            if isLoading && topics.isEmpty {
                ProgressView("正在拉取毕设信息…")
            } else if let errorMessage, topics.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") { Task { await load() } }
                }
            } else {
                List {
                    Section {
                        HStack {
                            Text("已选题数")
                                .font(.headline)
                            Spacer()
                            Text("\(selectedCount)")
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        .padding(.vertical, 4)
                    }
                    Section("选题列表") {
                        if topics.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("暂未选题")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("大四开题后这里会显示已选题目")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        } else {
                            ForEach($topics, id: \.id) { $topic in
                                let t = $topic.wrappedValue
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t.title)
                                        .font(.headline)
                                    if !t.teacher.isEmpty || !t.status.isEmpty {
                                        Text("\(t.teacher.isEmpty ? "—" : t.teacher)\(t.status.isEmpty ? "" : " · \(t.status)")")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("毕设")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            selectedCount = try await GXVNUService.fetchThesisCount()
            topics = try await GXVNUService.fetchThesisTopics()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "拉取失败，请稍后重试"
        }
    }
}
