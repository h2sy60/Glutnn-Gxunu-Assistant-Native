import SwiftUI

/// 首页（Flutter 版布局）：壁纸上的纯白文字 + 玻璃只做功能层。
/// 问候 + 日期/学期 + 下节课胶囊 + 三个操作胶囊 + 今日/明日课程（白字行）。
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: Int
    @State private var showExamsAlert = false

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
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "\(m)月\(d)日 · \(names[wd - 1])"
    }

    private var semesterLine: String {
        let term = appState.semester == "秋" ? "第一学期" : "第二学期"
        return "\(appState.year)-\(appState.year + 1) 学年\(term) · 第 \(appState.currentWeek) 周"
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 问候 + 更多按钮
                    HStack(alignment: .center) {
                        Text(appState.studentName.isEmpty ? greeting : "\(greeting)，\(appState.studentName)")
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

                    // 下节课胶囊
                    if let next = nextCourse {
                        Button { selectedTab = 1 } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.white)
                                Text("下节 · \(next.name) · \(next.location) · \(timeRange(next)) · \(relativeText(next))")
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

                    // 三个操作胶囊
                    HStack(spacing: 12) {
                        actionChip(icon: "arrow.clockwise", label: "刷新") {
                            Task { await appState.refreshSchedule() }
                        }
                        NavigationLink {
                            ScoreView()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                                Text("成绩")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                        actionChip(icon: "doc.text.fill", label: "考试") {
                            showExamsAlert = true
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

                    // 底部留白：内容别滑到悬浮玻璃导航栏下面去。
                    Spacer().frame(height: 140)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("考试功能即将上线", isPresented: $showExamsAlert) {
                Button("知道了", role: .cancel) {}
            }
        }
    }
}

#Preview {
    HomeView(selectedTab: .constant(0))
        .environment(AppState())
}
