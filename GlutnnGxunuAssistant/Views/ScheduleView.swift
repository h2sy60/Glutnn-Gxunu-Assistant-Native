import SwiftUI

// MARK: - 课表（原版 WakeUp 风，照 Flutter schedule.dart + bars.dart 一字不差）
//
// 顶栏：左“第 X 周 周Y”（20pt 粗黑，只在当前周才带“周Y”），右“导出”玻璃药丸 +
//      “2026-11-18📍”玻璃药丸；点标题或日期都回到当前周。没有左右箭头，没有日期范围。
// 周 strip：只有星期字（一 二 三 四 五 六 日），当天是黑色圆角 pill；
//      showDayByWeekDay 默认 false，所以不显示日期数字。
// 网格：白底 + 虚线网格 + 淡彩色块；左栏是节号 + 开始 + 结束时间；
//      块内是开始时间 + 全名（换行）+ 占两节以上再显示老师 + @教室（最多 3 行）。
//      行高按屏幕高度算：（屏幕高 − 180 − 85）/ 除数，夹在 50–92；
//      桂工除数 8.2（首屏 9 节）、职师院 9.2（首屏 10 节）。
// 切周：左右横滑；点标题/日期回到当前周。
//
// 下坠教训（build 21–28 全部栽在这，8 个版本）：
//      build 21–25：GeometryReader 换位置 / TabView 加显式高度——全败。
//      build 26：删 TabView——还下坠，TabView 不是病根。
//      build 27：删全部 GeometryReader——还下坠，GeometryReader 也不是病根。
//      build 28：包 NavigationStack——还下坠（Russell 10:09 亲装确认），
//      NavigationStack 也不是病根。
//      Russell 10:09：“我说了删了重构，天天守着你的屎山”。
//      他说得对：21–28 全是在同一套 VStack + 固定头 + 弹性 ScrollView 结构上
//      小修小补，从来没真正重构过。
//      build 29 是真重构：整个文件删了重写，结构全换——
//      根就是一个 ScrollView，里面 LazyVStack(pinnedViews: [.sectionHeaders])，
//      顶栏 + 星期条做成粘性 section header（滑到底也钉在顶部），
//      网格就是 section 内容。没有 VStack 包 ScrollView 的兄弟结构，
//      没有 NavigationStack，没有 TabView，没有 GeometryReader，
//      没有 .refreshable（课表页下拉刷新先拿掉，首页刷新芯片还在；
//      等布局站稳了再考虑加回来）。
//      不要再往这个文件里加回 VStack + ScrollView 兄弟结构，
//      也不要再加 GeometryReader / TabView / NavigationStack——
//      那 8 个版本已经证明那条路走不通。
// build 30（2026-11-18 10:21 Russell：29 下坠修好了，但左右切换动画没了、上下也滑不动）：
//      两个回归的病根都是 build 29 的 .highPriorityGesture(DragGesture)：
//      它把所有拖动都抢走了，ScrollView 收不到纵向滑动；
//      周一切换又是 .id(week) 整个重建 ScrollView 的瞬间替换，没有过渡动画。
//      修法：(1) .highPriorityGesture → .simultaneousGesture，
//      纵向归 ScrollView、横向归切周手势，两边都不抢；
//      (2) .id(week) 从 ScrollView 移到网格上，只换网格（顶栏不动），
//      加方向滑动过渡（下一周从右进、上一周从左进），切周包 withAnimation；
//      (3) ScrollViewReader + onChange(of: week) 切周后回到顶部。
// build 30 的两个新毛病（Russell 2026-11-18 10:36 亲装确认，图一二）：
//      (1) 上下滑穿模：网格内容滑到顶栏/星期条上面去了，顶栏被夹在网格中间；
//      (2) 左右滑切周会跳到顶部。
//      病根就是 build 30 新加的两样东西：网格上的 .transition(.move) +
//      ScrollViewReader.scrollTo(newWeek, anchor: .top)。
//      .transition 让 LazyVStack 的粘性 header 定位算错（网格在过渡里换位，
//      header 钉不住）；scrollTo 又在每次切周时把网格顶到视口最上方，
//      还把纵向滚动位置强行重置——原版切周根本不重置纵向位置
//      （Flutter 的 PageView 在 SingleChildScrollView 里，切周只换页，
//      纵向滑到哪还是哪）。
// build 31：删掉 .transition + scrollTo + .simultaneousGesture 切周手势，
//      周切换改回原生 TabView(.page)——这才是 Flutter PageView 的对应物，
//      滑动动画是系统自带的分页动画，不用自己拼 .transition。
//      关键：TabView 放在 LazyVStack 的 section 内容里（顶栏仍是粘性 header），
//      并给死高度（行高×11 + 底部留白），不让它自己量高度。
//      之前“不要带回 TabView”的教训是错的：build 26 已证明删 TabView
//      也修不好下坠（下坠的病根是外层 VStack 结构，build 29 的
//      LazyVStack 已修掉）；TabView 从来不是下坠的原因。
//      真正不能带回的只有：VStack + 固定头 + 弹性 ScrollView 的兄弟结构、
//      GeometryReader、NavigationStack、网格上的 .transition、scrollTo。

struct ScheduleView: View {
    @Environment(AppState.self) private var appState
    @State private var displayWeek: Int = 0
    @State private var showExportSoon = false

    private var week: Int { displayWeek == 0 ? appState.currentWeek : displayWeek }
    private var isCurrentWeek: Bool { week == appState.currentWeek }

    /// 某一周的课（TabView 每页一份）。
    private func courses(for targetWeek: Int) -> [Course] {
        appState.courses.filter { $0.weeks.contains(targetWeek) }
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

    /// 回到当前周（原版点标题/日期都回到当前周），TabView 自带分页动画。
    private func backToCurrentWeek() {
        let target = appState.currentWeek
        guard target != week else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            displayWeek = target
        }
    }

    /// 底部留白 = 浮动低栏高 + 底部边距（Flutter kBottomBarHeight + kBottomBarBottomMargin = 85 + 0）。
    private let bottomClearance: CGFloat = 85

    /// 行高按学校算：行高 =（屏幕高 − 180 − 85）/ 除数，夹在 50–92。
    /// 180 是顶栏 + strip + 上下安全区的合计估算；不用 GeometryReader 量。
    private var rowHeightValue: CGFloat {
        let divisor: CGFloat = appState.school.id == .gut ? 8.2 : 9.2
        let available = UIScreen.main.bounds.height - 180
        return min(92, max(50, (available - bottomClearance) / divisor))
    }

    /// 粘性顶栏（顶栏 + 星期条）：滑到底也钉在顶部，白底盖住下面滑过的网格。
    private var headerView: some View {
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
                    // 白底页上的玻璃药丸必须显式加白 tint：整 App 强制深色模式，
                    // 光靠 .preferredColorScheme(.light) 玻璃还是深灰（build 31 实测）。
                    .glassEffect(.regular.tint(.white.opacity(0.75)), in: Capsule())
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
                    .glassEffect(.regular.tint(.white.opacity(0.75)), in: Capsule())
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
        }
        .background(Color.white)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if appState.scheduleLoading && appState.courses.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView("正在拉取课表…")
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        // 周分页（原版 PageView 的对应物）：原生分页滑动动画，
                        // 横滑切周，纵向位置不动（不像 build 30 的 scrollTo 那样跳顶）。
                        // 给死高度，不让 TabView 自己量高度。
                        TabView(selection: Binding(
                            get: { week },
                            set: { displayWeek = $0 }
                        )) {
                            ForEach(1...20, id: \.self) { w in
                                let list = courses(for: w)
                                if list.isEmpty {
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
                                    .frame(maxWidth: .infinity, minHeight: 300)
                                    .tag(w)
                                } else {
                                    ScheduleGrid(
                                        courses: list,
                                        school: appState.school,
                                        rowHeight: rowHeightValue
                                    )
                                    .padding(.bottom, bottomClearance)
                                    .tag(w)
                                }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: rowHeightValue * CGFloat(appState.school.sectionCount) + bottomClearance)
                    }
                } header: {
                    headerView
                }
            }
        }
        .background(Color.white)
        .contentMargins(.top, 0, for: .scrollContent)
        // 课表是白底黑字的亮色页：整页用亮色模式，导出/日期玻璃药丸才是
        // 原版那种浅色玻璃；整 App 强制深色模式会让它俩变成深灰玻璃，丑。
        .preferredColorScheme(.light)
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
/// 列宽用屏幕宽直接算，不用 GeometryReader 量。
struct ScheduleGrid: View {
    let courses: [Course]
    let school: SchoolConfig
    let rowHeight: CGFloat

    /// 左侧栏宽（Flutter _railWidth = 46）。
    private let gutter: CGFloat = 46

    /// 每列宽 =（屏幕宽 − 两侧边距 16 − 左侧栏 46）/ 7。
    private var columnWidth: CGFloat {
        (UIScreen.main.bounds.width - 16 - gutter) / 7
    }

    /// 网格总宽 = 屏幕宽 − 两侧边距 16。
    private var gridWidth: CGFloat {
        UIScreen.main.bounds.width - 16
    }

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
        ZStack(alignment: .topLeading) {
            // 横虚线（每节一条）
            ForEach(0...school.sectionCount, id: \.self) { r in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: CGFloat(r) * rowHeight))
                    path.addLine(to: CGPoint(x: gridWidth, y: CGFloat(r) * rowHeight))
                }
                .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            // 竖虚线（每天一条）
            ForEach(0...7, id: \.self) { c in
                Path { path in
                    path.move(to: CGPoint(x: gutter + CGFloat(c) * columnWidth, y: 0))
                    path.addLine(to: CGPoint(x: gutter + CGFloat(c) * columnWidth, y: totalHeight))
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
                    let x = gutter + CGFloat(weekday - 1) * columnWidth + 2
                    let y = CGFloat(block.start - 1) * rowHeight + 2
                    let w = columnWidth - 4
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
        .frame(width: gridWidth, height: totalHeight)
        .padding(.horizontal, 8)
    }
}

#Preview {
    ScheduleView()
        .environment(AppState())
}
