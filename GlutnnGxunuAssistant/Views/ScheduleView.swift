import SwiftUI
import EventKit // 导出到日历（EventKit）：建日历、写课程事件、设提醒。

// MARK: - 课表（原版 WakeUp 风，照 Flutter schedule.dart + bars.dart 一字不差）
//
// 顶栏：左“第 X 周 周Y”（20pt 粗黑，只在当前周才带“周Y”），右“导出”玻璃药丸 +
//      “2026-11-18📍”玻璃药丸；点标题或日期都回到当前周。没有左右箭头，没有日期范围。
// 周 strip：只有星期字（一 二 三 四 五 六 日），当天是黑色圆角 pill；
//      showDayByWeekDay 默认 false，所以不显示日期数字。
// 网格：白底 + 虚线网格 + 淡彩色块 + 黑字（build 48：字色改回黑色、
//      比原来 0.85 再浅一点（默认不透明度 0.75），外观由「课表设置」调）；
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
// build 54（2026-11-18 23:06，专家意见）：顶部溢出——第 1–2 节课滑过顶栏顶到状态栏，
//      跟时间/电量叠在一起（Russell 22:52 截图，build 53 上仍在）。
//      build 52 删 .contentMargins(.top, 0) 是错的，contentMargins 不是病根。
//      真正原因有两个：(1) TabView(.page) 是 UIKit 的 UIPageViewController，放在
//      LazyVStack 的 section 内容里会破坏 pinnedViews 的粘性定位，顶栏钉不住；
//      (2) 顶栏就算钉住也只能钉在安全区顶沿（y=59pt），ScrollView 内容能滑到 y=0，
//      顶栏白底只盖自己那块、不盖状态栏那 59pt，课一滑上去就叠到时间/电量上。
//      修法：顶栏改用 ScrollView 的 .safeAreaInset(edge: .top, spacing: 0) 钉住，
//      不再用 LazyVStack 的 Section header；headerView 的背景改成
//      .background(Color.white, ignoresSafeAreaEdges: .top)，让白底向上延伸铺满
//      状态栏。根仍是单个全屏 ScrollView + LazyVStack(spacing: 0)，不会带回大白缝；
//      TabView、切周、点课程块、导出都不动。spacing: 0 和 ignoresSafeAreaEdges
//      缺一个都不行。
// build 54 失败（2026-11-18 23:58 Russell 截图）：safeAreaInset 把课表页彻底搞坏了——
//      顶栏被拉散（第12周+导出钉在顶部，星期条掉到屏幕中间），网格被顶到屏幕外、
//      第 1 节只能在屏幕最底下露个边，底栏还压在课上面。比 build 53 的溢出严重得多。
//      专家“绝对不会带回大白缝”的保证是错的。build 55 已回滚到 build 53 的布局。
// build 56（2026-11-19 00:05，专家二诊，一图破案）：元凶不是 safeAreaInset，
//      是 WeekDateStrip 里的 Color.clear.frame(width: 46)——Color.clear 宽高双向贪婪，
//      没锁高度；safeAreaInset 给 headerView 提议约 740pt 高，Color.clear 全吃掉，
//      星期字被 HStack 垂直居中顶到屏幕中间，网格被往下推 740pt。
//      同一行代码也是 build 21–28 大白缝的元凶（VStack 提议有限高度，Color.clear
//      撑爆）；LazyVStack 提议 height: nil，Color.clear 缩回 10pt 才把 Bug 藏住。
//      修法：Color.clear.frame(width: 46, height: 1) 治本；headerView 再加
//      .fixedSize(horizontal: false, vertical: true) 双重保险，永远只占紧凑高度。
//      body 恢复 build 54 的 safeAreaInset 写法，背景保留 ignoresSafeAreaEdges: .top。
// build 57（2026-11-19 00:28，照 WakeUp「课表外观」补齐设置）：
//      淡色盘 8→16 色（同款浅色系，不换色系）；每门课按名字排序顺序分色，
//      13 门课每门都不一样（名字哈希会撞色，改走色表；色表从全部课程算，换周不变）。
//      新增 16 个设置（ScheduleAppearance，加字段时旧数据用 decodeIfPresent 兜底，
//      不会丢已存设置）：边框颜色/虚线边框/边框用格子颜色/文字叠加格子颜色/
//      文字水平居中/垂直居中/自定义格子高度/显示非本周课程/非本周不透明比/
//      纯色背景/背景颜色/表头颜色/显示网格辅助线/节数栏显示时间/显示周六/显示周日。
//      隐藏周六/周日时列宽按显示天数重算（WeekDateStrip 和 ScheduleGrid 同步）；
//      非本周的课只显示不与本周课冲突的时段，淡色显示。

struct ScheduleView: View {
    @Environment(AppState.self) private var appState
    @State private var displayWeek: Int = 0
    @State private var showExportPage = false
    /// 点中的课程块（start/end 是合并后的节次范围），非空时弹课程详情。
    @State private var selectedBlock: (start: Int, end: Int, course: Course)?

    private var week: Int {
        let raw = displayWeek == 0 ? appState.currentWeek : displayWeek
        return min(max(raw, 1), 20) // 严格钳在 1...20，防止 UIPageViewController 越界（build 42）
    }
    private var isCurrentWeek: Bool { week == appState.currentWeek }

    /// 某一周的课（TabView 每页一份）。
    private func courses(for targetWeek: Int) -> [Course] {
        appState.courses.filter { $0.weeks.contains(targetWeek) }
    }

    /// 每门课固定一种颜色：把全部课程去重后按名字排序，顺序分色（色盘循环）。
    /// 13 门课、16 色时每门都不一样；课多于色时才循环重复。
    /// 比名字哈希稳定——哈希会撞色（build 57 前 8 色 13 门课必有重复）。
    /// 从全部课程算（不是当周），换周颜色不变；换学校自动重算。
    private var courseColorMap: [String: Color] {
        let names = Array(Set(appState.courses.map(\.name))).sorted()
        var map: [String: Color] = [:]
        for (i, name) in names.enumerated() {
            map[name] = coursePalette[i % coursePalette.count]
        }
        return map
    }

    /// 当前要显示的星期（1...7）：按设置隐藏周六/周日。
    private var visibleWeekdays: [Int] {
        var days = [1, 2, 3, 4, 5]
        if appState.scheduleAppearance.showSaturday { days.append(6) }
        if appState.scheduleAppearance.showSunday { days.append(7) }
        return days
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
    /// build 57：设置里改了自定义格子高度就用它（夹在 40–120）。
    private var rowHeightValue: CGFloat {
        if let custom = appState.scheduleAppearance.customRowHeight {
            return min(120, max(40, CGFloat(custom)))
        }
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
                        // build 57：表头颜色跟设置走。
                        .foregroundStyle(appState.scheduleAppearance.headerColor)
                }
                Spacer()
                HStack(spacing: 4) {
                    // 导出到日历（原版 ScheduleExportPage）。
                    Button {
                        showExportPage = true
                    } label: {
                        Text("导出")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.87))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    // 白底页上的玻璃药丸：窗口在课表页已是亮色，.regular 本身就是
                    // 浅色液态玻璃——不要再加白 tint。build 33 的教训：亮色窗口里
                    // .white.opacity(0.75) 会把玻璃顶成不透光的纯白扁片，液态玻璃感全丢。
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
            // build 57：按设置隐藏周六/周日；星期字颜色跟表头颜色走。
            WeekDateStrip(week: week, isCurrentWeek: isCurrentWeek, visibleWeekdays: visibleWeekdays, headerColor: appState.scheduleAppearance.headerColor)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        // build 56（专家二诊）：双重保险，强制顶栏永远只占自身紧凑高度（约 86pt），
        // 绝不被子视图撑高；白底向上延伸铺满状态栏安全区，挡住滑上去的课表。
        // build 57：顶栏背景色跟设置走（开纯色背景就用背景颜色，否则白底）。
        .fixedSize(horizontal: false, vertical: true)
        .background(appState.scheduleAppearance.effectiveBackgroundColor, ignoresSafeAreaEdges: .top)
    }

    var body: some View {
        // build 56（专家二诊，一图破案）：build 54 的 safeAreaInset 本身没错，元凶是
        // WeekDateStrip 里的 Color.clear.frame(width: 46)——Color.clear 宽高双向贪婪，
        // 没锁高度；safeAreaInset 给 headerView 提议了约 740pt 高，Color.clear 全吃掉，
        // 星期字被 HStack 垂直居中顶到屏幕中间，网格被往下推了 740pt。
        // 治本：Color.clear 锁死 height: 1；双重保险：headerView 加
        // .fixedSize(horizontal: false, vertical: true) 永远只占紧凑高度（约 86pt）。
        // build 21–28 的大白缝也是同一行代码害的（VStack 提议有限高度，Color.clear
        // 撑爆）；LazyVStack 提议 height: nil，Color.clear 缩回 10pt 才把 Bug 藏住。
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
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
                            // 单一 ZStack 包裹 if/else，只在最外层打唯一一个 .tag(w)：
                            // 原先两个分支各打 .tag(w)，换校时某周从“有课”变“无课”，
                            // 同一 tag 绑在结构身份不同的分支上，UIPageViewController
                            // 会销毁当前页控制器并触发崩溃（专家意见，build 42）。
                            ZStack {
                                // 空状态：本周没课，且（没开“显示非本周课程”或全学期都没课）才显示。
                                // 开了“显示非本周课程”时，本周没课也进网格看其他周的淡色课。
                                if list.isEmpty && (!appState.scheduleAppearance.showNonCurrentWeekCourses || appState.courses.isEmpty) {
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
                                } else {
                                    ScheduleGrid(
                                        courses: list,
                                        allCourses: appState.courses,
                                        currentWeek: w,
                                        school: appState.school,
                                        rowHeight: rowHeightValue,
                                        appearance: appState.scheduleAppearance,
                                        colorMap: courseColorMap,
                                        visibleWeekdays: visibleWeekdays,
                                        onSelect: { start, end, course in
                                            selectedBlock = (start, end, course)
                                        }
                                    )
                                    .padding(.bottom, bottomClearance)
                                }
                            }
                            .tag(w)
                        }
                    }
                    .id(appState.school.id) // 换校时干净重建分页器（build 42）
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: rowHeightValue * CGFloat(appState.school.sectionCount) + bottomClearance)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            headerView
        }
        // build 57：背景色跟设置走（开纯色背景就用背景颜色，否则白底）。
        .background(appState.scheduleAppearance.effectiveBackgroundColor)
        // 课表是白底黑字的亮色页：整页用亮色模式，导出/日期玻璃药丸才是
        // 原版那种浅色玻璃；整 App 强制深色模式会让它俩变成深灰玻璃，丑。
        .preferredColorScheme(.light)
        .onAppear { displayWeek = appState.currentWeek }
        // 换校时 displayWeek 跟着新学校的当前周走（配合 TabView 的 .id 重建，build 42）。
        .onChange(of: appState.school.id) { _, _ in
            displayWeek = appState.currentWeek
        }
        .fullScreenCover(isPresented: $showExportPage) {
            ScheduleExportView()
        }
        // 课程详情弹窗（点课程块弹出；点灰幕或 X 关闭）。
        .overlay {
            if let block = selectedBlock {
                CourseDetailPopup(
                    course: block.course,
                    startSection: block.start,
                    endSection: block.end,
                    school: appState.school,
                    onDismiss: { selectedBlock = nil }
                )
            }
        }
    }
}

/// 周 strip（原版 _Header）：只有星期字（一..日），当天是黑色圆角 pill。
/// 左侧留出和网格左侧栏一样的宽度（46），星期列才和网格的 7 天列对齐。
/// showDayByWeekDay 默认 false，所以不显示日期数字。
/// build 57：按设置隐藏周六/周日；星期字颜色跟表头颜色走。
struct WeekDateStrip: View {
    let week: Int
    let isCurrentWeek: Bool
    var visibleWeekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var headerColor: Color = .black

    private let weekdayChars = ["一", "二", "三", "四", "五", "六", "日"]

    private var todayIndex: Int {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return wd == 1 ? 7 : wd - 1
    }

    var body: some View {
        HStack(spacing: 0) {
            // build 56（专家二诊，治本）：Color.clear 宽高双向贪婪，没锁高度会在
            // safeAreaInset / VStack 里把提议的高度全吃掉，撑爆顶栏。锁死 height: 1。
            Color.clear.frame(width: 46, height: 1)
            ForEach(visibleWeekdays, id: \.self) { weekday in
                let i = weekday - 1
                let today = isCurrentWeek && (i + 1) == todayIndex
                Text(weekdayChars[i])
                    .font(.system(size: 13))
                    .foregroundStyle(today ? .white : headerColor.opacity(0.6))
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
/// 课程块配色（Russell 原来的淡色）。
/// build 47：Russell 2026-11-18 17:38 说 build 46 不该改色块颜色——
/// 只改文字颜色就好。淡色恢复，文字保持白字。
/// 名字哈希取色，同一门课颜色稳定。
/// build 57：淡色盘从 8 个扩到 16 个（同款浅色系，不换色系），13 门课每门都不一样。
private let coursePalette: [Color] = [
    Color(red: 0.98, green: 0.85, blue: 0.88), // 浅粉
    Color(red: 0.85, green: 0.90, blue: 0.99), // 浅蓝
    Color(red: 0.88, green: 0.85, blue: 0.98), // 浅紫
    Color(red: 0.99, green: 0.90, blue: 0.80), // 浅橙
    Color(red: 0.82, green: 0.95, blue: 0.90), // 浅薄荷
    Color(red: 0.99, green: 0.95, blue: 0.78), // 浅黄
    Color(red: 0.86, green: 0.93, blue: 0.86), // 浅绿
    Color(red: 0.95, green: 0.88, blue: 0.95), // 浅紫红
    Color(red: 0.99, green: 0.80, blue: 0.75), // 浅珊瑚
    Color(red: 0.75, green: 0.90, blue: 0.99), // 浅天蓝
    Color(red: 0.80, green: 0.82, blue: 0.99), // 浅靛蓝
    Color(red: 0.99, green: 0.87, blue: 0.65), // 浅金
    Color(red: 0.75, green: 0.93, blue: 0.93), // 浅水绿
    Color(red: 0.99, green: 0.78, blue: 0.88), // 浅玫红
    Color(red: 0.90, green: 0.95, blue: 0.75), // 浅柠檬绿
    Color(red: 0.93, green: 0.82, blue: 0.90), // 浅藕紫
]

/// 课程名稳定取色（和 Flutter courseColor 同一思路：名字哈希）。
private func courseColor(for name: String) -> Color {
    var hash = 0
    for scalar in name.unicodeScalars { hash = (hash &* 31) &+ Int(scalar.value) }
    return coursePalette[abs(hash) % coursePalette.count]
}

/// 把两个颜色按比例混合（取 RGB 平均，保留第一个颜色的透明度）。
/// “文字颜色叠加格子颜色”用：黑字 + 淡色块 = 深一点的彩色字。
/// 课表块和设置页预览共用。
private func blendColors(_ c1: Color, with c2: Color, ratio: Double) -> Color {
    let u1 = UIColor(c1)
    let u2 = UIColor(c2)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    guard u1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
          u2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return c1 }
    return Color(
        red: Double(r1 * (1 - ratio) + r2 * ratio),
        green: Double(g1 * (1 - ratio) + g2 * ratio),
        blue: Double(b1 * (1 - ratio) + b2 * ratio),
        opacity: Double(a1)
    )
}

struct ScheduleGrid: View {
    let courses: [Course]
    /// 全学期全部课程（只为“显示非本周课程”用）。
    var allCourses: [Course] = []
    /// 当前页是第几周（只为“显示非本周课程”判断用）。
    var currentWeek: Int = 0
    let school: SchoolConfig
    let rowHeight: CGFloat
    /// 课表外观（build 48）：文字颜色/字号/显示项/圆角/不透明度，按学校 + 学号保存。
    var appearance: ScheduleAppearance = .default
    /// 每门课固定一种颜色（按名字排序顺序分色；不在表里就退回名字哈希）。
    var colorMap: [String: Color] = [:]
    /// 要显示的星期（按设置隐藏周六/周日）。
    var visibleWeekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    /// 点课程块回调（start/end 是合并后的节次范围）。
    var onSelect: ((Int, Int, Course) -> Void)? = nil

    /// 左侧栏宽（Flutter _railWidth = 46）。
    private let gutter: CGFloat = 46

    /// 每列宽 =（屏幕宽 − 两侧边距 16 − 左侧栏 46）/ 显示天数。
    private var columnWidth: CGFloat {
        (UIScreen.main.bounds.width - 16 - gutter) / CGFloat(max(visibleWeekdays.count, 1))
    }

    /// 网格总宽 = 屏幕宽 − 两侧边距 16。
    private var gridWidth: CGFloat {
        UIScreen.main.bounds.width - 16
    }

    private func timeText(_ t: (Int, Int)) -> String {
        String(format: "%02d:%02d", t.0, t.1)
    }

    private var totalHeight: CGFloat { CGFloat(school.sectionCount) * rowHeight }

    /// 某天是第几列（0 起；只在显示的星期里找）。
    private func columnIndex(for weekday: Int) -> Int {
        visibleWeekdays.firstIndex(of: weekday) ?? 0
    }

    /// 把当天的课按节次拼成块：同名同地点的连续节次合并成一个块（Flutter _Grids 同款）。
    private func mergeBlocks(_ day: [Course]) -> [(start: Int, end: Int, course: Course)] {
        let sorted = day.sorted { $0.startSection < $1.startSection }
        var result: [(start: Int, end: Int, course: Course)] = []
        var i = 0
        while i < sorted.count {
            let c = sorted[i]
            var end = c.endSection
            var j = i + 1
            while j < sorted.count, sorted[j].name == c.name, sorted[j].location == c.location, sorted[j].startSection == end + 1 {
                end = sorted[j].endSection
                j += 1
            }
            result.append((start: c.startSection, end: end, course: c))
            i = j
        }
        return result
    }

    /// 某天的块：本周的课 +（开了“显示非本周课程”时）不与本周课冲突的其他周的课（淡色）。
    private func blocks(for weekday: Int) -> [(start: Int, end: Int, course: Course, isCurrentWeek: Bool)] {
        let current = mergeBlocks(courses.filter { $0.weekday == weekday })
        var result: [(start: Int, end: Int, course: Course, isCurrentWeek: Bool)] =
            current.map { (start: $0.start, end: $0.end, course: $0.course, isCurrentWeek: true) }
        if appearance.showNonCurrentWeekCourses {
            let occupied = current.map { ($0.start, $0.end) }
            let others = allCourses.filter { $0.weekday == weekday && !$0.weeks.contains(currentWeek) }
            for b in mergeBlocks(others) {
                // 只显示不与本周课冲突的时段，避免两个块重叠。
                let overlaps = occupied.contains { $0.0 <= b.end && b.start <= $0.1 }
                if !overlaps {
                    result.append((start: b.start, end: b.end, course: b.course, isCurrentWeek: false))
                }
            }
        }
        return result
    }

    /// 块内文字颜色：叠加格子色时混 50%；非本周的课再按不透明比淡化。
    private func textColor(for blockColor: Color, faded: Bool) -> Color {
        var c = appearance.textColor
        if appearance.textOverlaysBlockColor {
            c = blendColors(c, with: blockColor, ratio: 0.5)
        }
        if faded {
            c = c.opacity(appearance.nonCurrentWeekOpacity)
        }
        return c
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 横虚线（每节一条）+ 竖虚线（每天一条）：开“显示网格辅助线”才画。
            if appearance.showGridGuides {
                ForEach(0...school.sectionCount, id: \.self) { r in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: CGFloat(r) * rowHeight))
                        path.addLine(to: CGPoint(x: gridWidth, y: CGFloat(r) * rowHeight))
                    }
                    .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                ForEach(0...visibleWeekdays.count, id: \.self) { c in
                    Path { path in
                        path.move(to: CGPoint(x: gutter + CGFloat(c) * columnWidth, y: 0))
                        path.addLine(to: CGPoint(x: gutter + CGFloat(c) * columnWidth, y: totalHeight))
                    }
                    .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            // 左侧每节编号 + 开始时间 + 结束时间（Flutter _LeftGrid 同款）。
            // “节数栏显示时间”关了就只剩节次编号。
            ForEach(0..<school.sectionCount, id: \.self) { s in
                VStack(spacing: 1) {
                    Text("\(s + 1)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                    if appearance.showSectionTime {
                        Text(timeText(school.effectiveStartTimeList[s]))
                            .font(.system(size: 9))
                            .foregroundStyle(.black.opacity(0.45))
                        Text(timeText(school.effectiveEndTimeList[s]))
                            .font(.system(size: 9))
                            .foregroundStyle(.black.opacity(0.45))
                    }
                }
                .frame(width: gutter - 6, alignment: .center)
                .offset(x: 0, y: CGFloat(s) * rowHeight + 4)
            }
            // 课程块（按天分组，已合并连续节次；用开始节次做 id，同一门课分两段上时 id 不会撞）
            ForEach(visibleWeekdays, id: \.self) { weekday in
                ForEach(blocks(for: weekday), id: \.start) { block in
                    let x = gutter + CGFloat(columnIndex(for: weekday)) * columnWidth + 2
                    let y = CGFloat(block.start - 1) * rowHeight + 2
                    let w = columnWidth - 4
                    let h = CGFloat(block.end - block.start + 1) * rowHeight - 4
                    let span = block.end - block.start + 1
                    let tall = span >= 2
                    let atSign = appearance.showAtSign ? "@" : ""
                    // 块底色：按名字查固定色表（每门课一种色），不在表里退回名字哈希。
                    let blockColor = colorMap[block.course.name] ?? courseColor(for: block.course.name)
                    // 非本周的课：底色和文字都按不透明比淡化。
                    let faded = !block.isCurrentWeek
                    let bgOpacity = appearance.blockOpacity * (faded ? appearance.nonCurrentWeekOpacity : 1)
                    let text = textColor(for: blockColor, faded: faded)
                    // 边框色：开“边框使用格子颜色”就用块色，否则用边框颜色。
                    let border = appearance.borderUsesBlockColor ? blockColor : appearance.borderColor
                    VStack(alignment: appearance.textHorizontalCenter ? .center : .leading, spacing: 2) {
                        if appearance.textVerticalCenter { Spacer() }
                        if appearance.showStartTime {
                            Text(timeText(school.effectiveStartTimeList[block.start - 1]))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(text)
                        }
                        Text(block.course.name)
                            .font(.system(size: appearance.fontSize, weight: .bold))
                            .foregroundStyle(text)
                            .lineLimit(tall ? 4 : 2)
                            .multilineTextAlignment(appearance.textHorizontalCenter ? .center : .leading)
                        if tall && appearance.showTeacher {
                            Text(block.course.teacher)
                                .font(.system(size: 11))
                                .foregroundStyle(text)
                                .lineLimit(1)
                        }
                        if appearance.showLocation {
                            Text("\(atSign)\(block.course.location)")
                                .font(.system(size: 11))
                                .foregroundStyle(text)
                                .lineLimit(3)
                                .multilineTextAlignment(appearance.textHorizontalCenter ? .center : .leading)
                        }
                        if tall && appearance.showExtra, !block.course.extra.isEmpty {
                            Text(block.course.extra)
                                .font(.system(size: 10))
                                .foregroundStyle(text)
                                .lineLimit(2)
                                .multilineTextAlignment(appearance.textHorizontalCenter ? .center : .leading)
                        }
                        if appearance.textVerticalCenter { Spacer() }
                    }
                    .padding(.horizontal, appearance.textHorizontalCenter ? 0 : 4)
                    .frame(width: w, height: h)
                    .background(blockColor.opacity(bgOpacity), in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: appearance.cornerRadius)
                            .stroke(border, style: StrokeStyle(lineWidth: 1, dash: appearance.useDashedBorder ? [4, 4] : []))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
                    .onTapGesture { onSelect?(block.start, block.end, block.course) }
                    .offset(x: x, y: y)
                }
            }
        }
        .frame(width: gridWidth, height: totalHeight)
        .padding(.horizontal, 8)
    }
}

// MARK: - 课程详情弹窗（液态玻璃重设计，build 46）
//
// 图三旧版是扁平白卡（“课程信息”蓝标题 + “Course information” 灰副标题 +
// 灰字 label 行），不照抄。新版按 iOS 26 液态玻璃规范重做：
// 居中浮动玻璃卡（.glassEffect(.regular)），毛玻璃折射出身后课表；
// 课程名就是标题（大字粗体，配课程色圆点），不用“课程信息”当标题；
// 每行配 SF Symbol 图标（人/定位/日历/时钟），label 灰字、值深字粗体；
// 点卡外灰幕或右上玻璃 X 关闭。
struct CourseDetailPopup: View {
    let course: Course
    let startSection: Int
    let endSection: Int
    let school: SchoolConfig
    let onDismiss: () -> Void

    /// 星期字（一..日）。
    private var weekdayText: String {
        let chars = ["一", "二", "三", "四", "五", "六", "日"]
        guard (1...7).contains(course.weekday) else { return "—" }
        return chars[course.weekday - 1]
    }

    /// 周数压缩成区间：[1...12] → "1-12周"；[1,3,5] → "1、3、5周"。
    private var weeksText: String {
        let sorted = course.weeks.sorted()
        guard !sorted.isEmpty else { return "—" }
        var parts: [String] = []
        var start = sorted[0]
        var prev = sorted[0]
        for w in sorted.dropFirst() {
            if w == prev + 1 {
                prev = w
            } else {
                parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
                start = w
                prev = w
            }
        }
        parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
        return parts.joined(separator: "、") + "周"
    }

    /// 上课时钟范围（第 start 节开始时间 – 第 end 节结束时间）。
    private var timeRange: String {
        guard startSection >= 1, endSection >= startSection,
              startSection <= school.effectiveStartTimeList.count,
              endSection <= school.effectiveEndTimeList.count else { return "—" }
        let s = school.effectiveStartTimeList[startSection - 1]
        let e = school.effectiveEndTimeList[endSection - 1]
        return String(format: "%02d:%02d - %02d:%02d", s.0, s.1, e.0, e.1)
    }

    var body: some View {
        ZStack {
            // 灰幕：点外面关闭。
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            VStack(alignment: .leading, spacing: 0) {
                // 标题行：课程色圆点 + 课名 + 玻璃 X。
                HStack(spacing: 10) {
                    Circle()
                        .fill(courseColor(for: course.name))
                        .frame(width: 12, height: 12)
                    Text(course.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                        .lineLimit(2)
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                    .glassEffect(.clear, in: Circle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                Divider()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                VStack(spacing: 12) {
                    detailRow(icon: "person.fill", label: "教师", value: course.teacher)
                    detailRow(icon: "mappin", label: "地点", value: course.location)
                    detailRow(icon: "calendar", label: "周数", value: weeksText)
                    detailRow(icon: "clock.fill", label: "时间", value: "星期\(weekdayText) · 第\(startSection)-\(endSection)节")
                    detailRow(icon: "timer", label: "上课", value: timeRange)
                    if !course.extra.isEmpty {
                        detailRow(icon: "note.text", label: "备注", value: course.extra)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: 320)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    /// 信息行：图标 + 灰字 label + 深字粗体值。
    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.black.opacity(0.5))
                .frame(width: 20)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.black.opacity(0.5))
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(2)
            Spacer()
        }
    }
}

#Preview {
    ScheduleView()
        .environment(AppState())
}

// MARK: - 导出到日历（原版 ScheduleExportPage，lib/pages/schedule_export.dart）
//
// 全屏页：顶栏返回 + 标题 + 导出；说明文字 + 日历名称卡 + 提醒卡 + 页脚计数。
// 写入走 EventKit（原生无 device_calendar 可用）：删同名日历重建（蓝）、
// 每个 occurrence 独立事件（无 RRULE）、上课提醒相对闹钟、下课提醒绝对时间闹钟。
// 原生 Course 已是合并块（startSection..endSection），按 Course×weeks 展开即可，
// 不复现 Flutter 单节第 1 节丢课的边界 bug。

/// 课名缩短（Flutter lib/data.dart courseLongText2Short）：全角括号转半角 + 两门长课名缩写。
func shortCourseName(_ name: String) -> String {
    var s = name
        .replacingOccurrences(of: "（", with: "(")
        .replacingOccurrences(of: "）", with: ")")
    if s == "毛泽东思想和中国特色社会主义理论体系概论" { s = "毛概" }
    if s == "习近平新时代中国特色社会主义思想概论" { s = "习近平思想概论" }
    return s
}

/// 导出结果。
enum CalendarExportResult {
    case success(exported: Int, endAlarmAdded: Int, total: Int)
    case permission
    case failure(String)
}

/// EventKit 导出器。全部操作放 @MainActor：EKEventStore 不是线程安全的，
/// 主线程串行做最稳妥；每写 10 节让出一次，进度条才刷得动。
@MainActor
struct CalendarExporter {
    /// 某节课在某周的起止时间。termStart = 学期第一周周一。
    static func occurrenceRange(
        school: SchoolConfig, course: Course, week: Int
    ) -> (start: Date, end: Date)? {
        let cal = Calendar(identifier: .gregorian)
        guard week >= 1, course.weekday >= 1, course.weekday <= 7,
              course.startSection >= 1, course.startSection <= school.sectionCount,
              course.endSection >= course.startSection, course.endSection <= school.sectionCount
        else { return nil }
        // 日期 = 开学周一 + (week-1)*7 天 + (weekday-1) 天。
        guard let day = cal.date(
            byAdding: .day,
            value: (week - 1) * 7 + (course.weekday - 1),
            to: school.termStartDate
        ) else { return nil }
        let (sh, sm) = school.effectiveStartTimeList[course.startSection - 1]
        let (eh, em) = school.effectiveEndTimeList[course.endSection - 1]
        guard let start = cal.date(bySettingHour: sh, minute: sm, second: 0, of: day),
              let end = cal.date(bySettingHour: eh, minute: em, second: 0, of: day)
        else { return nil }
        return (start, end)
    }

    /// 待导出的 occurrence 总数（Course × weeks）。
    static func totalOccurrences(courses: [Course]) -> Int {
        courses.reduce(0) { $0 + $1.weeks.count }
    }

    /// 执行导出。onProgress(done, total) 回到主线程更新进度条。
    static func export(
        courses: [Course],
        school: SchoolConfig,
        calendarName: String,
        remindOn: Bool,
        remindMinutes: Int,
        secondRemind: Bool,
        endRemind: Bool,
        onProgress: @escaping (Int, Int) -> Void
    ) async -> CalendarExportResult {
        let store = EKEventStore()
        // 权限：要完全读写（删旧日历要读，写事件要写）。已拒绝/受限直接报权限错。
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            return .permission
        }
        if status != .fullAccess {
            do {
                let granted = try await store.requestFullAccessToEvents()
                if !granted { return .permission }
            } catch {
                return .permission
            }
        }
        // 删掉所有同名日历（重复导出不越导越多），再新建一本蓝日历。
        for cal in store.calendars(for: .event) where cal.title == calendarName {
            try? store.removeCalendar(cal, commit: true)
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarName
        calendar.cgColor = UIColor.blue.cgColor
        if let source = store.defaultCalendarForNewEvents?.source {
            calendar.source = source
        } else if let local = store.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = local
        } else if let first = store.sources.first {
            calendar.source = first
        }
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            return .failure("创建日历失败，请检查日历权限")
        }
        // 逐条写事件。
        let total = totalOccurrences(courses: courses)
        var done = 0
        var exported = 0
        var endAlarmAdded = 0
        var firstError: String?
        for course in courses {
            for week in course.weeks {
                guard let range = occurrenceRange(school: school, course: course, week: week) else {
                    done += 1
                    onProgress(done, total)
                    continue
                }
                // 结束 <= 开始是坏数据（Flutter 页上提示的「开始日期必须早于结束日期」）：
                // 只算一条失败，不中断整批；全部失败才报这个错。
                if range.end <= range.start {
                    if firstError == nil { firstError = "开始日期必须早于结束日期" }
                    done += 1
                    onProgress(done, total)
                    continue
                }
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = shortCourseName(course.name)
                event.location = (course.location.isEmpty || course.location == "未知") ? nil : course.location
                event.notes = course.teacher.isEmpty ? nil : "任课教师：\(course.teacher)"
                event.startDate = range.start
                event.endDate = range.end
                var alarms: [EKAlarm] = []
                if remindOn {
                    alarms.append(EKAlarm(relativeOffset: -Double(remindMinutes * 60)))
                    // 第二次提醒固定 5 分钟；首个已是 5 分钟时不再重复加。
                    if secondRemind && remindMinutes != 5 {
                        alarms.append(EKAlarm(relativeOffset: -5 * 60))
                    }
                }
                if endRemind {
                    alarms.append(EKAlarm(absoluteDate: range.end))
                }
                event.alarms = alarms.isEmpty ? nil : alarms
                do {
                    try store.save(event, span: .thisEvent, commit: true)
                    exported += 1
                    if endRemind { endAlarmAdded += 1 }
                } catch {
                    if firstError == nil { firstError = (error as NSError).localizedDescription }
                }
                done += 1
                onProgress(done, total)
                if done % 10 == 0 { await Task.yield() }
            }
        }
        if exported == 0 {
            return .failure(firstError ?? "写入失败")
        }
        return .success(exported: exported, endAlarmAdded: endAlarmAdded, total: total)
    }
}

/// 导出到日历页。
struct ScheduleExportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var calendarName = ""
    @State private var remindOn = true
    @State private var remindMinutes = 15
    @State private var secondRemind = false
    @State private var endRemind = false
    @State private var totalCount = 0
    @State private var exporting = false
    @State private var exportDone = 0
    @State private var exportTotal = 0
    @State private var resultMessage: String?
    @State private var resultTitle = ""
    @State private var showResult = false
    @State private var toastText: String?

    private let minuteOptions = [5, 10, 15, 30, 60]

    /// 开学日期（yyyy-MM-dd）。
    private var termStartText: String {
        let c = Calendar(identifier: .gregorian)
        let d = appState.school.termStartDate
        return "\(c.component(.year, from: d))-\(String(format: "%02d", c.component(.month, from: d)))-\(String(format: "%02d", c.component(.day, from: d)))"
    }

    private var hasCourses: Bool { !appState.courses.isEmpty }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                // 顶栏：返回 + 标题 + 导出。
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.87))
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular, in: Circle())
                    Spacer()
                    Text("导出到日历")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                    Spacer()
                    Button { Task { await doExport() } } label: {
                        Text("导出")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.87))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.regular, in: Capsule())
                    .disabled(exporting || !hasCourses)
                    .opacity(exporting || !hasCourses ? 0.5 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 开学日期说明。
                        Text(hasCourses
                             ? "当前课表设置的开学日期为 \(termStartText)，如果与实际不符，请刷新课表后重试"
                             : "尚未拉取课表，请先登录教务并刷新课表后再导出。")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.black.opacity(0.6))
                        // 权限说明。
                        Text("如果导出时提示日历不能写入，请去系统设置，找到「周周有善」并点击，更改日历权限为「完全读写」后再尝试导出")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.black.opacity(0.6))
                        // 日历名称卡。
                        HStack {
                            Text("日历名称")
                                .font(.system(size: 16))
                                .foregroundStyle(.black)
                            Spacer()
                            TextField("", text: $calendarName)
                                .font(.system(size: 16))
                                .foregroundStyle(.black)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        // 报错提示。
                        Text("如果导出时提示错误「开始日期必须早于结束日期」，说明课表里的上课时间有问题，存在下课时间早于上课时间的情况，请刷新课表后再尝试导出")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.black.opacity(0.6))
                        // 提醒卡。
                        VStack(spacing: 0) {
                            Toggle("上课提醒", isOn: $remindOn)
                                .font(.system(size: 16))
                                .padding(16)
                            Divider().padding(.leading, 16)
                            // 上课前几分钟提醒：Menu 选档位；上课提醒关时不可点 + 变淡。
                            HStack {
                                Text("上课前几分钟提醒")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.black)
                                Spacer()
                                Menu {
                                    ForEach(minuteOptions, id: \.self) { m in
                                        Button("\(m) 分钟") { remindMinutes = m }
                                    }
                                } label: {
                                    HStack(spacing: 2) {
                                        Text("\(remindMinutes) 分钟")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.black.opacity(0.6))
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.black.opacity(0.6))
                                    }
                                }
                                .disabled(!remindOn)
                            }
                            .padding(16)
                            .opacity(remindOn ? 1 : 0.4)
                            Divider().padding(.leading, 16)
                            Toggle("第二次提醒", isOn: $secondRemind)
                                .font(.system(size: 16))
                                .padding(16)
                                .disabled(!remindOn)
                                .opacity(remindOn ? 1 : 0.4)
                        }
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        // 下课提醒卡。
                        Toggle("下课提醒", isOn: $endRemind)
                            .font(.system(size: 16))
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        // 页脚计数。
                        Text(totalCount == 0 && hasCourses
                             ? "正在统计课程数量…"
                             : "共 \(totalCount) 节课，将写入系统日历「\(calendarName)」。"
                        )
                            .font(.system(size: 14))
                            .foregroundStyle(Color.black.opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
            // 导出进度（不可关闭）。
            if exporting {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在导出 \(exportDone)/\(exportTotal) 节课")
                        .font(.system(size: 15))
                        .foregroundStyle(.black)
                }
                .padding(24)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
            // 轻提示（名称空 / 无课程 / 其他错误）。
            if let toast = toastText {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.black.opacity(0.87))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.tint(.white.opacity(0.25)), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            if calendarName.isEmpty {
                calendarName = "\(appState.school.displayName) 课表"
            }
            totalCount = CalendarExporter.totalOccurrences(courses: appState.courses)
        }
        .alert(LocalizedStringKey(resultTitle), isPresented: $showResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func doExport() async {
        let name = calendarName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            flashToast("日历名称不能为空")
            return
        }
        if !hasCourses {
            flashToast("没有可导出的课程，请先登录并刷新课表")
            return
        }
        exporting = true
        exportDone = 0
        exportTotal = CalendarExporter.totalOccurrences(courses: appState.courses)
        let result = await CalendarExporter.export(
            courses: appState.courses,
            school: appState.school,
            calendarName: name,
            remindOn: remindOn,
            remindMinutes: remindMinutes,
            secondRemind: secondRemind,
            endRemind: endRemind
        ) { done, total in
            exportDone = done
            exportTotal = total
        }
        exporting = false
        switch result {
        case .success(let exported, let endAdded, _):
            resultTitle = "导出成功"
            var msg = "已写入 \(exported) 节课到系统日历「\(name)」。"
            if endRemind && endAdded < exported {
                msg += "\n\n注意：下课提醒只加上了 \(endAdded) 节，请检查日历权限。"
            }
            resultMessage = msg
            showResult = true
        case .permission:
            resultTitle = "日历不能写入"
            resultMessage = "请去系统设置，找到「周周有善」并点击，更改日历权限为「完全读写」后再尝试导出。"
            showResult = true
        case .failure(let message):
            flashToast(message)
        }
    }

    private func flashToast(_ text: String) {
        toastText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toastText == text { toastText = nil }
        }
    }
}

// MARK: - 课表设置页（build 48，参考 WakeUp「课表外观」；build 57 补齐 WakeUp 全部设置）
//
// 入口在“我的”页。调完即永久保存（按学校 + 学号），下次登录就是这套；
// 再调就覆盖保存。顶部是实时预览，改一项预览立刻变。
struct ScheduleSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            // 实时预览
            Section {
                HStack(spacing: 10) {
                    previewBlock(name: "高等数学B", teacher: "宋江艳", location: "4504D", time: "08:40", color: coursePalette[3], appearance: appState.scheduleAppearance)
                    previewBlock(name: "大学英语（一）", teacher: "李孟娜", location: "1203D", time: "08:40", color: coursePalette[0], appearance: appState.scheduleAppearance)
                    previewBlock(name: "中国近现代史纲要", teacher: "黄泽楷", location: "6402D", time: "08:40", color: coursePalette[1], appearance: appState.scheduleAppearance)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            } header: {
                Text("预览")
            }

            // 文字
            Section {
                ColorPicker("文字颜色", selection: Binding(
                    get: { Color(hex: appState.scheduleAppearance.textColorHex) },
                    set: { newColor in
                        var appearance = appState.scheduleAppearance
                        appearance.setTextColor(newColor)
                        appState.scheduleAppearance = appearance
                    }
                ))
                HStack {
                    Text("文字深浅")
                    Slider(value: $appState.scheduleAppearance.textOpacity, in: 0.3...1.0, step: 0.05)
                    Text("\(Int(appState.scheduleAppearance.textOpacity * 100))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                Stepper("字体大小：\(Int(appState.scheduleAppearance.fontSize))", value: $appState.scheduleAppearance.fontSize, in: 11...16, step: 1)
                Toggle("课程文字颜色叠加格子颜色", isOn: $appState.scheduleAppearance.textOverlaysBlockColor)
            } header: {
                Text("文字")
            }

            // 格子内显示
            Section {
                Toggle("格子内显示上课时间", isOn: $appState.scheduleAppearance.showStartTime)
                Toggle("格子内显示上课地点", isOn: $appState.scheduleAppearance.showLocation)
                Toggle("教室前显示 @", isOn: $appState.scheduleAppearance.showAtSign)
                Toggle("格子前显示授课老师", isOn: $appState.scheduleAppearance.showTeacher)
                Toggle("格子内显示备注", isOn: $appState.scheduleAppearance.showExtra)
                Toggle("格子文字水平居中", isOn: $appState.scheduleAppearance.textHorizontalCenter)
                Toggle("格子文字垂直居中", isOn: $appState.scheduleAppearance.textVerticalCenter)
            } header: {
                Text("格子内容")
            }

            // 格子外观
            Section {
                HStack {
                    Text("圆角半径")
                    Slider(value: $appState.scheduleAppearance.cornerRadius, in: 0...20, step: 1)
                    Text("\(Int(appState.scheduleAppearance.cornerRadius))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                HStack {
                    Text("格子不透明度")
                    Slider(value: $appState.scheduleAppearance.blockOpacity, in: 0.3...1.0, step: 0.05)
                    Text("\(Int(appState.scheduleAppearance.blockOpacity * 100))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                ColorPicker("边框颜色", selection: Binding(
                    get: { Color(hex: appState.scheduleAppearance.borderColorHex) },
                    set: { newColor in
                        var appearance = appState.scheduleAppearance
                        appearance.setBorderColor(newColor)
                        appState.scheduleAppearance = appearance
                    }
                ))
                .disabled(appState.scheduleAppearance.borderUsesBlockColor)
                Toggle("格子使用虚线边框", isOn: $appState.scheduleAppearance.useDashedBorder)
                Toggle("边框使用格子颜色", isOn: $appState.scheduleAppearance.borderUsesBlockColor)
                Toggle("自定义格子高度", isOn: Binding(
                    get: { appState.scheduleAppearance.customRowHeight != nil },
                    set: { on in
                        var a = appState.scheduleAppearance
                        a.customRowHeight = on ? (a.customRowHeight ?? 74) : nil
                        appState.scheduleAppearance = a
                    }
                ))
                Stepper("格子高度：\(Int(appState.scheduleAppearance.customRowHeight ?? 74))", value: Binding(
                    get: { appState.scheduleAppearance.customRowHeight ?? 74 },
                    set: { v in
                        var a = appState.scheduleAppearance
                        a.customRowHeight = v
                        appState.scheduleAppearance = a
                    }
                ), in: 40...120, step: 1)
                .disabled(appState.scheduleAppearance.customRowHeight == nil)
                Toggle("显示非本周课程", isOn: $appState.scheduleAppearance.showNonCurrentWeekCourses)
                HStack {
                    Text("非本周课程不透明比")
                    Slider(value: $appState.scheduleAppearance.nonCurrentWeekOpacity, in: 0.1...1.0, step: 0.05)
                    Text("\(Int(appState.scheduleAppearance.nonCurrentWeekOpacity * 100))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!appState.scheduleAppearance.showNonCurrentWeekCourses)
            } header: {
                Text("格子外观")
            }

            // 整体界面
            Section {
                Toggle("使用纯色背景", isOn: $appState.scheduleAppearance.useSolidBackground)
                ColorPicker("背景颜色", selection: Binding(
                    get: { Color(hex: appState.scheduleAppearance.backgroundColorHex) },
                    set: { newColor in
                        var appearance = appState.scheduleAppearance
                        appearance.setBackgroundColor(newColor)
                        appState.scheduleAppearance = appearance
                    }
                ))
                .disabled(!appState.scheduleAppearance.useSolidBackground)
                ColorPicker("表头颜色", selection: Binding(
                    get: { Color(hex: appState.scheduleAppearance.headerColorHex) },
                    set: { newColor in
                        var appearance = appState.scheduleAppearance
                        appearance.setHeaderColor(newColor)
                        appState.scheduleAppearance = appearance
                    }
                ))
                Toggle("显示网格辅助线", isOn: $appState.scheduleAppearance.showGridGuides)
                Toggle("节数栏显示时间", isOn: $appState.scheduleAppearance.showSectionTime)
                Toggle("显示周六", isOn: $appState.scheduleAppearance.showSaturday)
                Toggle("显示周日", isOn: $appState.scheduleAppearance.showSunday)
            } header: {
                Text("整体界面")
            }

            // 恢复默认
            Section {
                Button("恢复默认") {
                    appState.resetScheduleAppearance()
                }
                .foregroundStyle(.red)
            } footer: {
                Text("按当前学校 + 学号保存：\(appState.school.displayName) · \(appState.studentId.isEmpty ? "未登录" : appState.studentId)。换学校或换账号，各用各的一套。")
            }
        }
        .navigationTitle("课表设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appState.scheduleAppearance) { _, _ in
            appState.saveScheduleAppearance()
        }
    }

    /// 预览用的单个示例块（与课表块同款排版，含边框/对齐/文字叠加）。
    private func previewBlock(name: String, teacher: String, location: String, time: String, color: Color, appearance: ScheduleAppearance) -> some View {
        // 文字色：叠加格子色时混 50%。
        var text = appearance.textColor
        if appearance.textOverlaysBlockColor {
            text = blendColors(text, with: color, ratio: 0.5)
        }
        let border = appearance.borderUsesBlockColor ? color : appearance.borderColor
        return VStack(alignment: appearance.textHorizontalCenter ? .center : .leading, spacing: 2) {
            if appearance.textVerticalCenter { Spacer() }
            if appearance.showStartTime {
                Text(time)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(text)
            }
            Text(name)
                .font(.system(size: appearance.fontSize, weight: .bold))
                .foregroundStyle(text)
                .lineLimit(4)
                .multilineTextAlignment(appearance.textHorizontalCenter ? .center : .leading)
            if appearance.showTeacher {
                Text(teacher)
                    .font(.system(size: 11))
                    .foregroundStyle(text)
                    .lineLimit(1)
            }
            if appearance.showLocation {
                Text("\(appearance.showAtSign ? "@" : "")\(location)")
                    .font(.system(size: 11))
                    .foregroundStyle(text)
                    .lineLimit(3)
                    .multilineTextAlignment(appearance.textHorizontalCenter ? .center : .leading)
            }
            if appearance.textVerticalCenter { Spacer() }
        }
        .padding(.horizontal, appearance.textHorizontalCenter ? 0 : 4)
        .frame(width: 92, height: 110)
        .background(color.opacity(appearance.blockOpacity), in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: appearance.cornerRadius)
                .stroke(border, style: StrokeStyle(lineWidth: 1, dash: appearance.useDashedBorder ? [4, 4] : []))
        )
    }
}
