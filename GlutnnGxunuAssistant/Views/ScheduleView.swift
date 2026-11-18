import SwiftUI

// MARK: - 课表（原版 WakeUp 风，照 Flutter schedule.dart + bars.dart 一字不差）
//
// 顶栏：左“第 X 周 周Y”（20pt 粗黑，只在当前周才带“周Y”），右“导出”玻璃药丸 +
//      “2026-11-18📍”玻璃药丸；点标题或日期都回到当前周。没有左右箭头，没有日期范围。
// 周 strip：只有星期字（一 二 三 四 五 六 日），当天是黑色圆角 pill；
//      showDayByWeekDay 默认 false，所以不显示日期数字。
// 网格区：顶栏 + strip 固定在上；下面是一个普通纵向 ScrollView 填满剩余空间，
//      装 11 节网格（下滑看 10-11 节）。左右横滑切周（DragGesture），
//      点标题/日期回到当前周。
//      行高按网格区可用高度算：（可用高 − 85）/ 除数，夹在 50–92；
//      桂工除数 8.2（首屏 9 节）、职师院 9.2（首屏 10 节）。
// 下坠教训（build 21/22/23/25 都栽在这，build 25 已证实）：
//      page 式 TabView 的高度行为不可控——不管 GeometryReader 放页面里还是放外面、
//      不管给不给明确 frame 高度，顶栏和星期条之间都会出现大白空隙、网格掉到半屏。
//      build 25 把 GeometryReader 挪到 TabView 外面 + .frame(height:) 仍未修好，
//      Russell 09:30 证实 build 25 截图里下坠还在。所以 build 26 彻底去掉 TabView，
//      网格区只用普通 ScrollView（VStack 里能正常填满剩余空间，不会下坠），
//      切周改用横滑手势 + 点标题回当前周。不要再把 TabView 拿回来。

struct ScheduleView: View {
    @Environment(AppState.self) private var appState
    @State private var displayWeek: Int = 0
    @State private var showExportSoon = false

    private var week: Int { displayWeek == 0 ? appState.currentWeek : displayWeek }
    private var isCurrentWeek: Bool { week == appState.currentWeek }

    private var weekCourses: [Course] {
        appState.courses.filter { $0.weeks.contains(week) }
    }

    /// 今天星期几的字（一..日）。
    private var todayWeekdayChar: String {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        // Calendar weekday: 1=周日..7=周六；转成 1=周一..7=周日
        let idx = wd == 1 ? 7 : wd - 1
        return ["一", "二", "三", "四", "五", "六", "日"][idx - 1]
    }

    /// 今天日期（原版格式：2026-11-18，不补零）。
    private var todayDateText: String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        return "\(cal.component(.year, from: now))-\(cal.component(.month, from: now))-\(cal.component(.day, from: now))"
    }

    /// 回到当前周（原版点标题/日期都回到当前周）。
    private func backToCurrentWeek() {
        displayWeek = appState.currentWeek
    }

    /// 横滑切周：只有横向滑动明显大于纵向、且横向超过 60pt 时才切周；
    /// 纵向滑动留给 ScrollView 自己处理，不冲突。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) > 60 else { return }
                if dx < 0 {
                    displayWeek = min(20, week + 1)
                } else {
                    displayWeek = max(1, week - 1)
                }
            }
    }

    /// 底部留白 = 浮动低栏高 + 底部边距（Flutter kBottomBarHeight + kBottomBarBottomMargin = 85 + 0）。
    private let bottomClearance: CGFloat = 85

    /// 行高按学校算（Flutter schedule.dart 同款）：行高 =（网格区可用高 − 85）/ 除数，夹在 50–92。
    private func rowHeight(for availableHeight: CGFloat) -> CGFloat {
        let divisor: CGFloat = appState.school.id == .gut ? 8.2 : 9.2
        return min(92, max(50, (availableHeight - bottomClearance) / divisor))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏（原版 ScheduleTopBar）：左“第 X 周 周Y”，右“导出”+“日期📍”玻璃药丸。
            HStack {
                Button {
                    backToCurrentWeek()
                } label: {
                    Text("第\(week)周\(isCurrentWeek ? " 周\(todayWeekdayChar)" : "")")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                }
                Spacer()
                HStack(spacing: 4) {
                    // 导出到日历（原版跳 ScheduleExportPage；原生暂未实现，先提示）。
                    Button {
                        showExportSoon = true
                    } label: {
                        Text("导出")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.87))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.regular, in: Capsule())
                    // 日期 + 定位钉，点按回到当前周。
                    Button {
                        backToCurrentWeek()
                    } label: {
                        HStack(spacing: 2) {
                            Text(todayDateText)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.87))
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.black.opacity(0.87))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .glassEffect(.regular, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // 周 strip（原版 _Header）：只有星期字，当天黑色 pill；不显示日期数字。
            WeekDateStrip(week: week, isCurrentWeek: isCurrentWeek)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 10)

            // 网格区（build 26）：不再用 TabView。普通纵向 ScrollView 填满剩余空间，
            // GeometryReader 只用来量高度算行高，不再用它去定任何视图的 frame，
            // 不再有“量高度 → 定高度”的循环依赖。横滑切周用 highPriorityGesture，
            // 切周时 .id(week) 让 ScrollView 回到顶部。
            GeometryReader { geo in
                let rh = rowHeight(for: geo.size.height)
                if appState.scheduleLoading && appState.courses.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView("正在拉取课表…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if weekCourses.isEmpty {
                    VStack {
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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        ScheduleGrid(
                            courses: weekCourses,
                            school: appState.school,
                            rowHeight: rh
                        )
                        .padding(.bottom, bottomClearance)
                    }
                    .id(week)
                    .refreshable {
                        if !appState.isLoggedIn {
                            appState.showLoginSheet = true
                        } else {
                            await appState.refreshSchedule()
                        }
                    }
                }
            }
            .highPriorityGesture(swipeGesture)
        }
        .background(Color.white)
        .onAppear { displayWeek = appState.currentWeek }
        .alert("导出功能即将上线", isPresented: $showExportSoon) {
            Button("知道了", role: .cancel) {}
        }
    }
}

/// 周 strip（原版 _Header）：只有星期字（一..日），当天是黑色圆角 pill。
/// 左侧留出和网格左侧栏一样的宽度（46），星期列才和网格的 7 天列对齐。
/// showDayByWeekDay 默认 false，所以不显示日期数字。
struct WeekDateStrip: View {
    let week: Int
    let isCurrentWeek: Bool

    private let weekdayChars = ["一", "二", "三", "四", "五", "六", "日"]

    private var todayIndex: Int {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return wd == 1 ? 7 : wd - 1
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 46)
            ForEach(0..<7, id: \.self) { i in
                let today = isCurrentWeek && (i + 1) == todayIndex
                Text(weekdayChars[i])
                    .font(.system(size: 13))
                    .foregroundStyle(today ? .white : .black.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        today
                            ? Color.black.opacity(0.85)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(.horizontal, 10)
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
