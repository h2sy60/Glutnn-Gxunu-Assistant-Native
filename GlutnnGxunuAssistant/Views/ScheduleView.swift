import SwiftUI

// MARK: - 课表（Flutter 版白底 WakeUp 风）：白底 + 顶栏 + 周日期条 + 左右划切周 + 按学校算行高
//
// 结构和 Flutter schedule.dart 一字不差：
//   顶栏（第 X 周 + 日期范围 + 左右切周，固定）
//   周日期条（星期 + 日期，当天黑色 pill，固定）
//   剩余区域：纵向 ScrollView，里面是定高（行高×11）的横向 TabView（每页一周网格）+ 底部 85 留白。
// 顶栏和日期条在 TabView 外面，不跟着划走；TabView 只装网格，不在每页里再套 ScrollView。
// build 21 的错：TabView 每页里套 ScrollView，又没给 TabView 定高，
// 布局一乱，日期条就被顶到屏幕中间去了。

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

    /// 底部留白 = 浮动低栏高 + 底部边距（Flutter kBottomBarHeight + kBottomBarBottomMargin = 85）。
    private let bottomClearance: CGFloat = 85

    /// 行高按学校算（Flutter schedule.dart 同款）：行高 =（剩余高度 − 85）/ 除数，夹在 50–92。
    /// 桂工除数 8.2（首屏 9 节）、职师院 9.2（首屏 10 节）。
    /// 注意：这里的剩余高度是顶栏 + 日期条之后剩下的，不是整屏高（build 21 错在拿整屏高算，行高顶到 92）。
    private func rowHeight(for availableHeight: CGFloat) -> CGFloat {
        let divisor: CGFloat = appState.school.id == .gut ? 8.2 : 9.2
        return min(92, max(50, (availableHeight - bottomClearance) / divisor))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：第 X 周 + 日期范围 + 左右切周（固定，不划走）
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

            // 周日期条：星期 + 日期，当天是黑色圆角 pill（固定，不划走）
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
                // 网格区：纵向能滑，横向划动切周。TabView 只装网格，定高，不在每页里套 ScrollView。
                GeometryReader { geo in
                    let rh = rowHeight(for: geo.size.height)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            TabView(selection: $displayWeek) {
                                ForEach(1...20, id: \.self) { w in
                                    ScheduleGrid(
                                        courses: appState.courses.filter { $0.weeks.contains(w) },
                                        school: appState.school,
                                        rowHeight: rh
                                    )
                                    .tag(w)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(height: rh * CGFloat(appState.school.sectionCount))
                            // 底部留白：滑到底最后一节也能完整露出来，不被低栏盖住。
                            Color.clear.frame(height: bottomClearance)
                        }
                    }
                    .refreshable {
                        if !appState.isLoggedIn {
                            appState.showLoginSheet = true
                        } else {
                            await appState.refreshSchedule()
                        }
                    }
                }
            }
        }
        .background(Color.white)
        .onAppear { displayWeek = appState.currentWeek }
    }
}

/// 周日期条：周一到周日，星期 + 日期；当天黑色 pill 白字。
/// 左侧留出和网格左侧栏一样的宽度（46），日期列才和网格的 7 天列对齐。
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
            Color.clear.frame(width: 46)
            ForEach(0..<7, id: \.self) { i in
                let d = date(of: i)
                let today = isToday(d)
                VStack(spacing: 2) {
                    Text(weekdayChars[i])
                        .font(.system(size: 13))
                        .foregroundStyle(today ? .white : .black.opacity(0.6))
                    Text("\(Calendar(identifier: .gregorian).component(.day, from: d))")
                        .font(.system(size: 15, weight: today ? .bold : .regular))
                        .foregroundStyle(today ? .white : .black.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(today ? Color.black.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// 周网格：11 节 × 7 天，白底 + 虚线网格 + 淡彩色块。
/// 块内布局和 Flutter _Grid 一样：顶部是开始时间，中间是全名（换行），占两节以上再显示老师，底部 @教室（最多 3 行）。
struct ScheduleGrid: View {
    let courses: [Course]
    let school: SchoolConfig
    let rowHeight: CGFloat

    /// 左侧栏宽（Flutter _railWidth = 46）。
    private let gutter: CGFloat = 46

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

    /// 把当天的课按节次拼成块：同名同地点的连续节次合并成一个块（Flutter _Grids 同款）。
    private func blocks(for weekday: Int) -> [(start: Int, end: Int, course: Course)] {
        let day = courses.filter { $0.weekday == weekday }.sorted { $0.startSection < $1.startSection }
        var result: [(start: Int, end: Int, course: Course)] = []
        var i = 0
        while i < day.count {
            let c = day[i]
            var end = c.endSection
            var j = i + 1
            while j < day.count, day[j].name == c.name, day[j].location == c.location, day[j].startSection == end + 1 {
                end = day[j].endSection
                j += 1
            }
            result.append((start: c.startSection, end: end, course: c))
            i = j
        }
        return result
    }

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
                    // 左侧每节编号 + 开始时间 + 结束时间（Flutter _LeftGrid 同款）
                    ForEach(0..<school.sectionCount, id: \.self) { s in
                        VStack(spacing: 1) {
                            Text("\(s + 1)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black.opacity(0.85))
                            Text(timeText(school.startTimeList[s]))
                                .font(.system(size: 9))
                                .foregroundStyle(.black.opacity(0.45))
                            Text(timeText(school.endTimeList[s]))
                                .font(.system(size: 9))
                                .foregroundStyle(.black.opacity(0.45))
                        }
                        .frame(width: gutter - 6, alignment: .center)
                        .offset(x: 0, y: CGFloat(s) * rowHeight + 4)
                    }
                    // 课程块（按天分组，已合并连续节次；用开始节次做 id，同一门课分两段上时 id 不会撞）
                    ForEach(1...7, id: \.self) { weekday in
                        ForEach(blocks(for: weekday), id: \.start) { block in
                            let x = gutter + CGFloat(weekday - 1) * colW + 2
                            let y = CGFloat(block.start - 1) * rowHeight + 2
                            let w = colW - 4
                            let h = CGFloat(block.end - block.start + 1) * rowHeight - 4
                            let span = block.end - block.start + 1
                            let tall = span >= 2
                            VStack(spacing: 2) {
                                Text(timeText(school.startTimeList[block.start - 1]))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.85))
                                Text(block.course.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.85))
                                    .lineLimit(tall ? 4 : 2)
                                    .multilineTextAlignment(.center)
                                if tall {
                                    Text(block.course.teacher)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.black.opacity(0.6))
                                        .lineLimit(1)
                                }
                                Text("@\(block.course.location)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.black.opacity(0.6))
                                    .lineLimit(3)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: w, height: h)
                            .background(color(for: block.course.name), in: RoundedRectangle(cornerRadius: 10))
                            .offset(x: x, y: y)
                        }
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
