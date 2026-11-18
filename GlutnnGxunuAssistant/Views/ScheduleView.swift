import SwiftUI

// MARK: - 课表（Flutter 版白底 WakeUp 风）：白底 + 顶栏 + 周日期条 + 左右划切周 + 按学校算行高
//
// 颜色和 Flutter 一致：白底黑字，淡彩色块；不是壁纸深色风。

struct ScheduleView: View {
    @Environment(AppState.self) private var appState
    @State private var displayWeek: Int = 0

    private var week: Int { displayWeek == 0 ? appState.currentWeek : displayWeek }

    private var weekCourses: [Course] {
        appState.courses.filter { $0.weeks.contains(week) }
    }

    /// 本周周一（termStartDate 就是第 1 周的周一）。
    private func monday(of week: Int) -> Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(byAdding: .day, value: (week - 1) * 7, to: appState.school.termStartDate) ?? Date()
    }

    /// 本周起止日期（“11月16日 - 11月22日”）。
    private var weekRangeText: String {
        let cal = Calendar(identifier: .gregorian)
        let mon = monday(of: week)
        let sun = cal.date(byAdding: .day, value: 6, to: mon) ?? mon
        let fmt: (Date) -> String = { d in
            "\(cal.component(.month, from: d))月\(cal.component(.day, from: d))日"
        }
        return "\(fmt(mon)) - \(fmt(sun))"
    }

    /// 行高按学校算（Flutter schedule.dart 同款）：桂工除数 8.2（首屏 9 节）、职师院 9.2（首屏 10 节），夹在 50–92。
    private func rowHeight(for availableHeight: CGFloat) -> CGFloat {
        let divisor: CGFloat = appState.school.id == .gut ? 8.2 : 9.2
        return min(92, max(50, availableHeight / divisor))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 顶栏：第 X 周 + 日期范围 + 左右切周
                HStack {
                    Button {
                        if week > 1 { displayWeek = week - 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(6)
                    }
                    .disabled(week <= 1)
                    Spacer()
                    VStack(spacing: 2) {
                        Text("第 \(week) 周")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.black)
                        Text(weekRangeText)
                            .font(.system(size: 13))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                    Spacer()
                    Button {
                        if week < 20 { displayWeek = week + 1 }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(6)
                    }
                    .disabled(week >= 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)

                // 周日期条：星期 + 日期，当天是黑色圆角 pill
                WeekDateStrip(week: week, monday: monday(of: week))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)

                if appState.scheduleLoading && appState.courses.isEmpty {
                    Spacer()
                    ProgressView("正在拉取课表…")
                    Spacer()
                } else if weekCourses.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.black.opacity(0.4))
                        Text(appState.scheduleError ?? "本周没有课程")
                            .font(.subheadline)
                            .foregroundStyle(.black.opacity(0.7))
                            .multilineTextAlignment(.center)
                        Button("重新拉取") {
                            Task { await appState.refreshSchedule() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    Spacer()
                } else {
                    // 左右划动切周（每页一个周网格）
                    TabView(selection: $displayWeek) {
                        ForEach(1...20, id: \.self) { w in
                            ScrollView {
                                ScheduleGrid(
                                    courses: appState.courses.filter { $0.weeks.contains(w) },
                                    school: appState.school,
                                    rowHeight: rowHeight(for: geo.size.height)
                                )
                                .padding(.top, 6)
                                .padding(.bottom, 140)
                            }
                            .tag(w)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .background(Color.white)
        }
        .onAppear { displayWeek = appState.currentWeek }
        .refreshable {
            await appState.refreshSchedule()
        }
    }
}

/// 周日期条：周一到周日，星期 + 日期；当天黑色 pill 白字。
struct WeekDateStrip: View {
    let week: Int
    let monday: Date

    private let weekdayChars = ["一", "二", "三", "四", "五", "六", "日"]

    private func date(of offset: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: monday) ?? monday
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar(identifier: .gregorian).isDateInToday(date)
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 42)
            ForEach(0..<7, id: \.self) { i in
                let d = date(of: i)
                let today = isToday(d)
                VStack(spacing: 2) {
                    Text(weekdayChars[i])
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(today ? .white : .black)
                    Text("\(Calendar(identifier: .gregorian).component(.day, from: d))")
                        .font(.system(size: 13))
                        .foregroundStyle(today ? .white : .black.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(today ? Color.black : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// 周网格：11 节 × 7 天，白底 + 虚线网格 + 淡彩色块（块内含时间）。
struct ScheduleGrid: View {
    let courses: [Course]
    let school: SchoolConfig
    let rowHeight: CGFloat

    private let gutter: CGFloat = 42

    private let pastel: [Color] = [
        Color(red: 0.98, green: 0.85, blue: 0.88),
        Color(red: 0.85, green: 0.90, blue: 0.99),
        Color(red: 0.88, green: 0.85, blue: 0.98),
        Color(red: 0.99, green: 0.90, blue: 0.80),
        Color(red: 0.82, green: 0.95, blue: 0.90),
        Color(red: 0.99, green: 0.95, blue: 0.78),
        Color(red: 0.86, green: 0.93, blue: 0.86),
        Color(red: 0.95, green: 0.88, blue: 0.95),
    ]

    /// 课程名稳定取色（和 Flutter courseColor 同一思路：名字哈希）。
    private func color(for name: String) -> Color {
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31) &+ Int(scalar.value) }
        return pastel[abs(hash) % pastel.count]
    }

    private func timeText(_ t: (Int, Int)) -> String {
        String(format: "%02d:%02d", t.0, t.1)
    }

    private var totalHeight: CGFloat { CGFloat(school.sectionCount) * rowHeight }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let colW = (geo.size.width - gutter) / 7
                ZStack(alignment: .topLeading) {
                    // 横虚线（每节一条）
                    ForEach(0...school.sectionCount, id: \.self) { r in
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: CGFloat(r) * rowHeight))
                            path.addLine(to: CGPoint(x: geo.size.width, y: CGFloat(r) * rowHeight))
                        }
                        .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    // 竖虚线（每天一条）
                    ForEach(0...7, id: \.self) { c in
                        Path { path in
                            path.move(to: CGPoint(x: gutter + CGFloat(c) * colW, y: 0))
                            path.addLine(to: CGPoint(x: gutter + CGFloat(c) * colW, y: totalHeight))
                        }
                        .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    // 左侧每节编号 + 开始时间
                    ForEach(0..<school.sectionCount, id: \.self) { s in
                        VStack(spacing: 1) {
                            Text("\(s + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.7))
                            Text(timeText(school.startTimeList[s]))
                                .font(.system(size: 10))
                                .foregroundStyle(.black.opacity(0.5))
                        }
                        .frame(width: gutter - 6, alignment: .center)
                        .offset(x: 0, y: CGFloat(s) * rowHeight + 4)
                    }
                    // 课程块
                    ForEach(courses) { course in
                        let x = gutter + CGFloat(course.weekday - 1) * colW + 2
                        let y = CGFloat(course.startSection - 1) * rowHeight + 2
                        let w = colW - 4
                        let h = CGFloat(course.endSection - course.startSection + 1) * rowHeight - 4
                        let start = timeText(school.startTimeList[course.startSection - 1])
                        let end = timeText(school.endTimeList[course.endSection - 1])
                        VStack(spacing: 2) {
                            Text(course.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.85))
                                .lineLimit(3)
                                .multilineTextAlignment(.center)
                            Text("\(start)-\(end)")
                                .font(.system(size: 10))
                                .foregroundStyle(.black.opacity(0.6))
                                .lineLimit(1)
                            if h > 60 {
                                Text(course.location)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.black.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: w, height: h)
                        .background(color(for: course.name), in: RoundedRectangle(cornerRadius: 10))
                        .offset(x: x, y: y)
                    }
                }
                .frame(height: totalHeight)
            }
            .frame(height: totalHeight)
        }
        .padding(.horizontal, 8)
    }
}

#Preview {
    ScheduleView()
        .environment(AppState())
}
