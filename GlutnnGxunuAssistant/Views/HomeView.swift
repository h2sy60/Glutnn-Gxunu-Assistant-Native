import SwiftUI

/// 首页（Flutter 版布局）：壁纸上的纯白文字 + 玻璃只做功能层。
/// 问候 + 日期/学期 + 下节课胶囊（两行）+ 操作胶囊（一行：刷新/成绩/考试/更多）
/// + 今天/明天课程（按节展开，每节一行，带状态）。
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: Int
    @State private var showExams = false
    @State private var showScores = false
    /// 更多功能（build 58 两校都有）：职师院待办/评教/学分/教学计划/个人信息/学籍预警；
    /// 桂工教学计划/空教室查询。
    @State private var showMore = false
    /// 刷新防刷计数（原版 home.dart refresh() 同款）：点 7 下“你太快了!”，
    /// 8 下以上“你慢一点!”+ 5 秒冷却。
    @State private var refreshClickCount = 0
    @State private var refreshCooldown = false
    /// 正在分段刷新时，再来的刷新请求直接跳过（防重叠）。
    @State private var isRefreshing = false
    /// 首页显示开关（build 63 首页设置）：用 @AppStorage 读同一个键，
    /// 设置页一改首页立即重绘（AppSettings 不是 Observable，直接读不会刷新）。
    @AppStorage("ShowRecentExams") private var showRecentExams = true
    @AppStorage("ShowTomorrowCourses") private var showTomorrowCourses = true
    @AppStorage("ShowGreeting") private var showGreeting = true

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

    /// 待考的考试（build 60，旧项目 ExamsTipsBar 同款意图，但旧项目只显示
    /// 写死的占位卡片；原生显示真实数据）。按时间排，最多 3 场。
    /// 时间串以日期开头（YYYY-MM-DD），字典序即时间序；“时间待定”
    /// 排最后。
    private var upcomingExams: [ExamItem] {
        appState.exams
            .filter { !$0.isPast }
            .sorted { $0.time < $1.time }
            .prefix(3)
            .map { $0 }
    }

    /// 一节课（原版 todaySchedule 是按节展开的：跨两节的课占两行，每节自己的开始/结束时间与状态）。
    private struct DaySection: Identifiable {
        let id: Int
        let course: Course
        let section: Int
    }

    /// 今天的每一节（按节次展开并排序）。
    private var todaySections: [DaySection] {
        var out: [DaySection] = []
        for c in todayCourses {
            for s in c.startSection...c.endSection {
                out.append(DaySection(id: s, course: c, section: s))
            }
        }
        return out.sorted { $0.section < $1.section }
    }
    private var tomorrowSections: [DaySection] {
        var out: [DaySection] = []
        for c in tomorrowCourses {
            for s in c.startSection...c.endSection {
                out.append(DaySection(id: s, course: c, section: s))
            }
        }
        return out.sorted { $0.section < $1.section }
    }

    /// 问候语（Flutter glassGreeting 同款：23 点后是“夜深了”）。
    private var greeting: String {
        let hour = Calendar(identifier: .gregorian).component(.hour, from: Date())
        switch hour {
        case 0..<6: return "夜深了"
        case 6..<9: return "早上好"
        case 9..<12: return "上午好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    /// 日期行（原版 glassDateLine：11月18日 · 周三，用“周X”不是“星期X”）。
    private var dateLine: String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "\(m)月\(d)日 · \(names[cal.component(.weekday, from: now) - 1])"
    }

    /// 学期行（原版 glassSemesterLine 同款公式与文案）：
    /// 进度 = 周×5% − 5% + 星期/7×5%，取整；提示按周数分段。
    private var semesterLine: String {
        let week = appState.currentWeek
        if week > 20 { return "学期已经结束咯" }
        if week <= 0 { return "新学期即将到来" }
        let weekday = Double(todayWeekday)
        let progress = (Double(week) * 5 / 100) - 0.05 + (weekday / 7 * 5 / 100)
        let percent = Int(progress * 100)
        let tip: String
        if week >= 15 { tip = "期末来临，复习为重" }
        else if week >= 10 { tip = "学期过半，珍惜当下" }
        else if week >= 5 { tip = "已过小半，集中精力" }
        else { tip = "开学不久，好好玩吧" }
        return "本学期第 \(week) 周 · \(tip) · 已完成 \(percent)%"
    }

    private func startTime(of section: Int) -> (Int, Int) {
        // build 60：用生效时间（时间管理改过就用自定义，否则学校默认作息）。
        let list = appState.school.effectiveStartTimeList
        guard section >= 1, section <= list.count else { return (0, 0) }
        return list[section - 1]
    }

    private func endTime(of section: Int) -> (Int, Int) {
        // build 60：同上。
        let list = appState.school.effectiveEndTimeList
        guard section >= 1, section <= list.count else { return (0, 0) }
        return list[section - 1]
    }

    private func timeRange(section: Int) -> String {
        let s = startTime(of: section)
        let e = endTime(of: section)
        return String(format: "%02d:%02d - %02d:%02d", s.0, s.1, e.0, e.1)
    }

    /// 某一节的状态（原版 lists.dart timeUntilNextClass + timeText 同款口径）。
    /// 返回右边的文字与状态：before = 还没上，after = 已开始（含已结束）。
    /// 文案：已结束 / X分后下课 / X分后上课 / X小时后 / ""（4 小时开外不显示）。
    /// dayOffset：0 = 今天，1 = 明天。明天的课还没发生，直接返回 before，
    /// 不拿今天的时间去比——不然明天的第 1–5 节（12:00 前结束）按今天
    /// 14:48 算全是“已结束”，全打勾（Russell 2026-11-18 14:48）。
    private func sectionStatus(section: Int, dayOffset: Int = 0) -> (text: String, state: String) {
        if dayOffset > 0 { return ("", "before") }
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let s = startTime(of: section)
        let e = endTime(of: section)
        let startMin = s.0 * 60 + s.1
        let endMin = e.0 * 60 + e.1
        let startDiff = startMin - nowMin
        if startDiff > 0 {
            if startDiff >= 240 { return ("", "before") }
            if startDiff >= 60 {
                let h = startDiff / 60
                let m = startDiff % 60
                return (m == 0 ? "\(h)小时后" : "\(h)小时\(m)分后", "before")
            }
            return ("\(startDiff)分后上课", "before")
        }
        let endDiff = endMin - nowMin
        if endDiff > 0 { return ("\(endDiff)分后下课", "after") }
        return ("已结束", "after")
    }

    /// 某行右边显示的状态文案（原版 lists.dart 同款规则）：
    /// 上一行的文案里有“后”（正在倒计时），这一行就不显示，免得满屏都是倒计时。
    private func statusTextForRow(at index: Int, in sections: [DaySection]) -> String {
        let (text, _) = sectionStatus(section: sections[index].section)
        if index > 0 {
            let (prevText, _) = sectionStatus(section: sections[index - 1].section)
            if prevText.contains("后") { return "" }
        }
        return text
    }

    /// 某节的图标与颜色（原版 lists.dart icon/timeColor 同款）：
    /// 未上 = 计时器白字，正在上 = 羽毛笔主题蓝，已结束 = 对勾白 70%。
    private func sectionIcon(section: Int, dayOffset: Int = 0) -> (name: String, color: Color) {
        let (text, state) = sectionStatus(section: section, dayOffset: dayOffset)
        if state == "before" { return ("timer", .white) }
        if text.contains("下课") { return ("pencil", .blue) }
        return ("checkmark", Color.white.opacity(0.7))
    }

    /// 行文字颜色（和图标同一口径）。
    private func sectionTextColor(section: Int, dayOffset: Int = 0) -> Color {
        let (text, state) = sectionStatus(section: section, dayOffset: dayOffset)
        if state == "before" { return .white }
        if text.contains("下课") { return .blue }
        return Color.white.opacity(0.7)
    }

    /// 下节课胶囊的目标（图二旧版写法）：
    /// 正在上课时显示正在上的那节（标题“正在上”，第二行“X分后下课”）；
    /// 没课在上时显示第一节还没上的（标题“下节”，第二行“X分后上课”）。
    /// build 45：修正 build 31 照搬的 Flutter 怪癖（正在上却显示下一节课名），
    /// Russell 2026-11-18 17:06 截图确认那是错的：17:03 第 8 节中国近现代史纲要
    /// 还在上，胶囊却写了 19:30 的环境化学。按图二旧版改回来。
    private var pillTarget: (section: DaySection, isCurrent: Bool)? {
        // 先找正在上的。
        for s in todaySections {
            let (text, state) = sectionStatus(section: s.section)
            if state == "after" && !text.contains("已结束") {
                return (s, true)
            }
        }
        // 没在上，找第一节还没上的（下节）。
        for s in todaySections {
            let (_, state) = sectionStatus(section: s.section)
            if state == "before" {
                return (s, false)
            }
        }
        return nil
    }

    /// 操作胶囊（玻璃圆角矩形 + 图标 + 文字）。
    private func actionChip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    /// 今天/明天课程行（原版 lists.dart _TodayCourseListItem 同款）：
    /// 左图标 + 两行白字（第一行“教室 课名”，第二行“第X节 | 老师”）+ 右边状态文案。
    private func sectionRow(_ daySection: DaySection, statusText: String, dayOffset: Int = 0) -> some View {
        let (iconName, iconColor) = sectionIcon(section: daySection.section, dayOffset: dayOffset)
        let textColor = sectionTextColor(section: daySection.section, dayOffset: dayOffset)
        let location = daySection.course.location
            .replacingOccurrences(of: "未知", with: "")
            .trimmingCharacters(in: .whitespaces)
        return HStack(alignment: .top, spacing: 0) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 28, alignment: .center)
                .padding(.trailing, 8)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    if !location.isEmpty {
                        Text(location + " ")
                            .font(.system(size: 16))
                            .foregroundStyle(textColor)
                    }
                    Text(daySection.course.name)
                        .font(.system(size: 16))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                }
                Text("第\(daySection.section)节 | \(daySection.course.teacher)")
                    .font(.system(size: 12))
                    .foregroundStyle(textColor.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer()
            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - 刷新（原版 home.dart refresh() 同款，带分段提示条）

    /// 分段刷新：提示条序列 + 拉课表 + 结果提示。任何触发点都走这里，
    /// 提示条永远显示（Russell 2026-11-18 10:36：更新一定要显示，不管在哪里，
    /// 包括回到前台的自动刷新，不静默）。
    private func performStagedRefresh() async {
        guard appState.isLoggedIn else {
            appState.showLoginSheet = true
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        appState.showToast(.loading, "准备更新...", duration: 10)
        try? await Task.sleep(for: .seconds(1))
        appState.showToast(.loading, "连接教务...", duration: 10)
        appState.showToast(.loading, "获取课表...", duration: 10)
        let wasLoggedIn = appState.isLoggedIn
        await appState.refreshSchedule()
        if appState.showCaptchaDialog {
            // 验证码弹窗已弹（职师院两次都要求验证码）：等用户输码，
            // 结果提示条由 confirmCaptchaDialog 发，这里不发任何提示条。
        } else if appState.scheduleError == nil {
            appState.showToast(.loading, "处理数据...", duration: 10)
            appState.showToast(.success, "数据已更新!", duration: 1)
        } else if wasLoggedIn {
            // build 67：只有真是会话过期才弹“需要验证”走验证码弹窗；
            // 解析失败/网络错误要显示真实原因，不然用户被误导去输验证码，
            // 输完了课表还是拉不到（Russell 2026-11-19 09:14 的遭遇：
            // 桂工会话过期返回 302 空正文，被误报成“课表解析失败”，
            // 却弹了“需要验证”）。
            // refreshSchedule 里桂工/职师院会话过期都记成“登录已过期，请重新登录”。
            if appState.scheduleError == "登录已过期，请重新登录" {
                appState.showToast(.error, "需要验证", duration: 10, action: .reverify)
            } else {
                appState.showToast(.error, appState.scheduleError ?? "拉取失败", duration: 4)
            }
        } else {
            appState.showToast(.error, appState.scheduleError ?? "拉取失败", duration: 4)
        }
    }

    /// 点“刷新”胶囊 / 下拉刷新：防刷计数 + 分段刷新。
    private func refreshWithFeedback() async {
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
        await performStagedRefresh()
        refreshClickCount = 0
    }

    /// 回到前台不自动刷新（Russell 2026-11-18 13:05：只有点首页“刷新”按钮才更新课表，
    /// 不然老是请求）。旧版 layout.dart 的 resumed 自动刷新已删；刷新只走
    /// 首页“刷新”胶囊和下拉刷新，都是手动。
    var body: some View {
        NavigationStack {
            ZStack {
                // 壁纸打底（和我的页、登录页同款放法）：TabView + NavigationStack 的底是不透明的，
                // 只靠 WindowGroup 那层壁纸透不过来，首页就全黑。壁纸必须放在本页自己的 ZStack 底层。
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 问候（Flutter 问候语不带人名；build 63 首页设置可关）
                    HStack(alignment: .center) {
                        if showGreeting {
                            Text(greeting)
                                .font(.system(size: 44, weight: .heavy))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                        }
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

                    // 下节课胶囊（原版 GlassNextClassPill 同款，两行）：
                    // 第一行“正在上/下节 · 课名”，第二行“教室 · 开始-结束 · X分后上课/下课”。
                    if let pill = pillTarget {
                        let relative = sectionStatus(section: pill.section.section).text
                        let location = pill.section.course.location
                            .replacingOccurrences(of: "未知", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        Button { selectedTab = 1 } label: {
                            HStack(spacing: 10) {
                                Image(systemName: pill.isCurrent ? "pencil" : "timer")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(pill.isCurrent ? "正在上" : "下节") · \(pill.section.course.name)")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("\(location.isEmpty ? "" : "\(location) · ")\(timeRange(section: pill.section.section))\(relative.isEmpty ? "" : " · \(relative)")")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                        .padding(.top, 20)
                        .padding(.horizontal, 20)
                    }

                    // 操作胶囊（一行，居中；未登录时点它们弹登录页，登录后才做事）。
                    // 刷新 / 成绩 / 考试三项两校都有；更多两校都有——职师院是
                    // 待办/评教/学分/教学计划/个人信息/学籍预警等，桂工是教学计划/空教室查询。
                    HStack(spacing: 8) {
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
                                showExams = true
                            }
                        }
                        actionChip(icon: "ellipsis.circle.fill", label: "更多") {
                            if !appState.isLoggedIn {
                                appState.showLoginSheet = true
                            } else {
                                showMore = true
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                    // 近期考试（build 60，旧项目 ExamsTipsBar 同款位置：首页胶囊下方）。
                    // 只在登录且有待考考试时出现，点按进完整考试列表。
                    // build 63 首页设置可关。
                    if showRecentExams, appState.isLoggedIn, !upcomingExams.isEmpty {
                        Text("近期考试")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 0) {
                            ForEach(upcomingExams) { exam in
                                Button {
                                    showExams = true
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(exam.courseName)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(exam.time)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.white.opacity(0.7))
                                                .lineLimit(1)
                                            if !exam.location.isEmpty {
                                                Text(exam.location)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.white.opacity(0.7))
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 20)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if exam.id != upcomingExams.last?.id {
                                    Divider().background(Color.white.opacity(0.15))
                                }
                            }
                        }
                    }

                    // 今日课程（Russell 2026-11-18 10:56：改回今日课程/明日课程）
                    Text("今日课程")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 24)
                        .padding(.horizontal, 20)

                    if todaySections.isEmpty {
                        Text("今天没有课")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 10)
                            .padding(.horizontal, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(todaySections.enumerated()), id: \.element.id) { index, daySection in
                                sectionRow(daySection, statusText: statusTextForRow(at: index, in: todaySections))
                                if daySection.id != todaySections.last?.id {
                                    Divider().background(Color.white.opacity(0.15))
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // 明日课程（build 63 首页设置可关）
                    if showTomorrowCourses {
                        Text("明日课程")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.top, 20)
                            .padding(.horizontal, 20)

                        if tomorrowSections.isEmpty {
                            Text("明天没有课")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.top, 10)
                                .padding(.horizontal, 20)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(tomorrowSections) { daySection in
                                sectionRow(daySection, statusText: "", dayOffset: 1)
                                if daySection.id != tomorrowSections.last?.id {
                                    Divider().background(Color.white.opacity(0.15))
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
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
            .task {
                // 近期考试条要数据：登录后、还没拉过考试时静默拉一次。
                // 失败也不弹提示，条子不出现就是了。
                if appState.isLoggedIn, appState.exams.isEmpty, appState.examsError == nil {
                    await appState.refreshExams()
                }
                // build 63 通用设置：启动时自动刷新（默认关；Russell 2026-11-18
                // 定手动刷新为主，这个开关默认关，不改现有行为）。
                if AppSettings.autoRefreshOnLaunch, appState.isLoggedIn {
                    await refreshWithFeedback()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showExams) {
                ExamsView()
            }
            .navigationDestination(isPresented: $showScores) {
                ScoreView()
            }
            .navigationDestination(isPresented: $showMore) {
                // build 58：更多按学校分流——桂工 GUTMoreView，职师院 GXVNUMoreView。
                if appState.school.id == .gut {
                    GUTMoreView()
                } else {
                    GXVNUMoreView()
                }
            }
        }
    }
}
}

#Preview {
    HomeView(selectedTab: .constant(0))
        .environment(AppState())
}
