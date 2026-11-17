import SwiftUI

// MARK: - 课表：Flutter 版周网格（壁纸 + 淡彩色块 + 每节时间）

struct ScheduleView: View {
    @Environment(AppState.self) private var appState
    @State private var displayWeek: Int = 0

    private var week: Int { displayWeek == 0 ? appState.currentWeek : displayWeek }

    private var weekCourses: [Course] {
        appState.courses.filter { $0.weeks.contains(week) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 周切换玻璃胶囊
            HStack {
                Button {
                    if week > 1 { displayWeek = week - 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                }
                .disabled(week <= 1)
                Spacer()
                Text("第 \(week) 周")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    if week < 20 { displayWeek = week + 1 }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                }
                .disabled(week >= 20)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 8)
            .padding(.horizontal, 20)

            if appState.scheduleLoading && appState.courses.isEmpty {
                Spacer()
                ProgressView("正在拉取课表…")
                    .foregroundStyle(.white)
                Spacer()
            } else if weekCourses.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(appState.scheduleError ?? "本周没有课程")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Button("重新拉取") {
                        Task { await appState.refreshSchedule() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    ScheduleGrid(courses: weekCourses, school: appState.school)
                        .padding(.top, 14)
                        .padding(.bottom, 140)
                }
                .refreshable {
                    await appState.refreshSchedule()
                }
            }
        }
        .onAppear { displayWeek = appState.currentWeek }
    }
}

/// 周网格：11 节 × 7 天，淡彩色块 + 左侧每节开始时间。
struct ScheduleGrid: View {
    let courses: [Course]
    let school: SchoolConfig

    private let gutter: CGFloat = 42
    private let rowHeight: CGFloat = 52

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
            // 星期标题行
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                ForEach(1...7, id: \.self) { d in
                    Text(["一", "二", "三", "四", "五", "六", "日"][d - 1])
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)

            GeometryReader { geo in
                let colW = (geo.size.width - gutter) / 7
                ZStack(alignment: .topLeading) {
                    // 横线（每节一条）
                    ForEach(0...school.sectionCount, id: \.self) { r in
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: geo.size.width, height: 1)
                            .offset(x: 0, y: CGFloat(r) * rowHeight)
                    }
                    // 竖线（每天一条）
                    ForEach(0...7, id: \.self) { c in
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: totalHeight)
                            .offset(x: gutter + CGFloat(c) * colW, y: 0)
                    }
                    // 左侧每节开始时间
                    ForEach(0..<school.sectionCount, id: \.self) { s in
                        Text(timeText(school.startTimeList[s]))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: gutter - 6, alignment: .trailing)
                            .offset(x: 0, y: CGFloat(s) * rowHeight + 4)
                    }
                    // 课程块
                    ForEach(courses) { course in
                        let x = gutter + CGFloat(course.weekday - 1) * colW + 2
                        let y = CGFloat(course.startSection - 1) * rowHeight + 2
                        let w = colW - 4
                        let h = CGFloat(course.endSection - course.startSection + 1) * rowHeight - 4
                        VStack(spacing: 2) {
                            Text(course.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.85))
                                .lineLimit(3)
                                .multilineTextAlignment(.center)
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
