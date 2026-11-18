import SwiftUI

/// 首页（Flutter 版布局）：壁纸上的纯白文字 + 玻璃只做功能层。
/// 问候 + 日期/学期 + 下节课胶囊 + 三个操作胶囊 + 今日/明日课程（白字行）。
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: Int
    @Environment(\.scenePhase) private var scenePhase
    @State private var showExamsAlert = false
    @State private var showScores = false
    /// 刷新防刷计数（原版 home.dart refresh() 同款）：点 7 下“你太快了!”，
    /// 8 下以上“你慢一点!”+ 5 秒冷却。
    @State private var refreshClickCount = 0
    @State private var refreshCooldown = false

    /// 今天星期几（1=星期一 … 7=星期日）。
    private var todayWeekday: Int {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return wd == 1 ? 7 : wd - 1
    }
    private var tomorrowWeekday: Int { todayWeekday % 7 + 1 }

    private var todayCourses: [Course] {
        appState.courses
            .filter { $0.weekday == todayWeekday && $0.weeks.contains(appState.currentWeek) }
            .sorted { $0.startSection < $1.startSection }
    }
    private var tomorrowCourses: [Course] {
        appState.courses
            .filter { $0.weekday == tomorrowWeekday && $0.weeks.contains(appState.currentWeek) }
            .sorted { $0.startSection < $1.startSection }
    }

    /// 问候语（按小时，和 Flutter glassGreeting 一致）。
    private var greeting: String {
        let hour = Calendar(identifier: .gregorian).component(.hour, from: Date())
        switch hour {
        case 0..<6: return "夜深了"
        case 6..<9: return "早上好"
        case 9..<12: return "上午好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private var dateLine: String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        let wd = cal.component(.weekday, from: now)
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return "\(m)月\(d)日 · \(names[wd - 1])"
    }

    /// 学期行（Flutter 同款）：第 X 周 · 已完成 N%；周 > 20 显示“学期已经结束咯”。
    private var semesterLine: String {
        let week = appState.currentWeek
        if week > 20 { return "学期已经结束咯" }
        let term = appState.semester == "秋" ? "第一学期" : "第二学期"
        let pct = min(100, week * 100 / 20)
        return "\(appState.year)-\(appState.year + 1) 学年\(term) · 第 \(week) 周 · 已完成 \(pct)%"
    }

    private func startTime(of course: Course) -> (Int, Int) {
        let list = appState.school.startTimeList
        guard course.startSection >= 1, course.startSection <= list.count else { return (0, 0) }
        return list[course.startSection - 1]
    }

    private func endTime(of course: Course) -> (Int, Int) {
        let list = appState.school.endTimeList
        guard course.endSection >= 1, course.endSection <= list.count else { return (0, 0) }
        return list[course.endSection - 1]
    }

    private func timeRange(_ course: Course) -> String {
        let s = startTime(of: course)
        let e = endTime(of: course)
        return String(format: "%02d:%02d - %02d:%02d", s.0, s.1, e.0, e.1)
    }

    /// 今天还没结束的最近一节（正在上或即将上）。
    private var nextCourse: Course? {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        for c in todayCourses {
            let e = endTime(of: c)
            if nowMin < e.0 * 60 + e.1 { return c }
        }
        return nil
    }

    /// 这节课现在是否正在上（当前时间在开始–结束之间）。
    private func isNow(_ course: Course) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let s = startTime(of: course)
        let e = endTime(of: course)
        return nowMin >= s.0 * 60 + s.1 && nowMin < e.0 * 60 + e.1
    }

    private func relativeText(_ course: Course) -> String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let s = startTime(of: course)
        let e = endTime(of: course)
        let startMin = s.0 * 60 + s.1
        let endMin = e.0 * 60 + e.1
        if nowMin < startMin {
            let diff = startMin - nowMin
            if diff >= 60 { return "\(diff / 60)小时\(diff % 60)分后上课" }
            return "\(diff)分后上课"
        }
        if nowMin < endMin { return "\(endMin - nowMin)分后下课" }
        return "已结束"
    }

    /// 操作胶囊（玻璃圆角矩形 + 图标 + 文字）。
    private func actionChip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    /// 今日/明日课程行：纯白文字，无卡片。
    private func courseRow(_ course: Course) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(course.teacher) · \(course.location)")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Text(timeRange(course))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.vertical, 10)
    }

    // MARK: - 刷新（原版 home.dart refresh() 同款，带分段提示条）

    /// 点“刷新”胶囊 / 下拉刷新：分段提示条 + 防刷计数。
    /// 流程：准备更新... →（1 秒后）连接教务... → 获取课表... →
    /// 成功：处理数据... → 数据已更新!；会话过期且已登录：需要验证（点按弹登录页）；
    /// 未登录：弹登录页；其他失败：显示错误原文。
    private func refreshWithFeedback() async {
        if !appState.isLoggedIn {
            appState.showLoginSheet = true
            return
        }
        refreshClickCount += 1
        if refreshClickCount == 7 {
            appState.showToast(.error, "你太快了!")
            return
        }
        if refreshClickCount >= 8 {
            if !refreshCooldown {
                refreshCooldown = true
                appState.showToast(.error, "你慢一点!")
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    refreshClickCount = 0
                    refreshCooldown = false
                }
            }
            return
        }
        appState.showToast(.loading, "准备更新...", duration: 10)
        try? await Task.sleep(for: .seconds(1))
        appState.showToast(.loading, "连接教务...", duration: 10)
        appState.showToast(.loading, "获取课表...", duration: 10)
        let wasLoggedIn = appState.isLoggedIn
        await appState.refreshSchedule()
        if appState.scheduleError == nil {
            appState.showToast(.loading, "处理数据...", duration: 10)
            appState.showToast(.success, "数据已更新!", duration: 1)
        } else if wasLoggedIn {
            // 会话过期：原版弹“需要验证”玻璃条，点按回首页重新登录。
            appState.showToast(.error, "需要验证", duration: 10, action: .showLogin)
        } else {
            appState.showToast(.error, appState.scheduleError ?? "拉取失败", duration: 4)
        }
        refreshClickCount = 0
    }

    /// 回到前台时静默刷新一次（原版 layout.dart：AppLifecycleState.resumed 时
    /// reinitialize(refreshState: true)）。不弹提示条，不打扰。
    private func refreshOnForeground() {
        guard appState.isLoggedIn else { return }
        Task { await appState.refreshSchedule() }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 壁纸打底（和我的页、登录页同款放法）：TabView + NavigationStack 的底是不透明的，
                // 只靠 WindowGroup 那层壁纸透不过来，首页就全黑。壁纸必须放在本页自己的 ZStack 底层。
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 问候（Flutter 问候语不带人名）
                    HStack(alignment: .center) {
                        Text(greeting)
                            .font(.system(size: 44, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                        Spacer()
                        Button { selectedTab = 2 } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                    }
                    .padding(.top, 64)
                    .padding(.horizontal, 20)

                    Text(dateLine)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 6)
                        .padding(.horizontal, 20)

                    Button { selectedTab = 1 } label: {
                        Text(semesterLine)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 20)

                    // 下节课胶囊（正在上 / 下节，Flutter GlassNextClassPill 同款）
                    if let next = nextCourse {
                        Button { selectedTab = 1 } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.white)
                                Text("\(isNow(next) ? "正在上" : "下节") · \(next.name) · \(next.location) · \(timeRange(next)) · \(relativeText(next))")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 20)
                        .padding(.horizontal, 20)
                    }

                    // 三个操作胶囊（旧版：未登录时点它们弹登录页，登录后才做事）
                    HStack(spacing: 12) {
                        actionChip(icon: "arrow.clockwise", label: "刷新") {
                            Task { await refreshWithFeedback() }
                        }
                        actionChip(icon: "chart.bar.fill", label: "成绩") {
                            if !appState.isLoggedIn {
                                appState.showLoginSheet = true
                            } else {
                                showScores = true
                            }
                        }
                        actionChip(icon: "doc.text.fill", label: "考试") {
                            if !appState.isLoggedIn {
                                appState.showLoginSheet = true
                            } else {
                                showExamsAlert = true
                            }
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                    // 今日课程
                    Text("今日课程")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 24)
                        .padding(.horizontal, 20)

                    if todayCourses.isEmpty {
                        Text("今天没有课")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 10)
                            .padding(.horizontal, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(todayCourses) { course in
                                courseRow(course)
                                if course.id != todayCourses.last?.id {
                                    Divider().background(Color.white.opacity(0.15))
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // 明日课程
                    Text("明日课程")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 20)
                        .padding(.horizontal, 20)

                    if tomorrowCourses.isEmpty {
                        Text("明天没有课")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 10)
                            .padding(.horizontal, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(tomorrowCourses) { course in
                                courseRow(course)
                                if course.id != tomorrowCourses.last?.id {
                                    Divider().background(Color.white.opacity(0.15))
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // 未登录提示（旧版 _LoginTip 同款）：点一下进登录页，不拦着看首页。
                    if !appState.isLoggedIn {
                        Button {
                            appState.showLoginSheet = true
                        } label: {
                            Text("请先登录")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    // 底部留白：内容别滑到悬浮玻璃导航栏下面去。
                    Spacer().frame(height: 140)
                }
            }
            .refreshable {
                await refreshWithFeedback()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { refreshOnForeground() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("考试功能即将上线", isPresented: $showExamsAlert) {
                Button("知道了", role: .cancel) {}
            }
            .navigationDestination(isPresented: $showScores) {
                ScoreView()
            }
        }
    }
}
}

#Preview {
    HomeView(selectedTab: .constant(0))
        .environment(AppState())
}
