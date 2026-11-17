import SwiftUI

/// 首页：顶部玻璃导航条 + 今日课程。背景由 WindowGroup 层的渐变提供。
struct HomeView: View {
    @Environment(AppState.self) private var appState

    /// 今天星期几（1=星期一 … 7=星期日）。
    private var todayWeekday: Int {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return wd == 1 ? 7 : wd - 1
    }

    private var todayCourses: [Course] {
        appState.courses
            .filter { $0.weekday == todayWeekday && $0.weeks.contains(appState.currentWeek) }
            .sorted { $0.startSection < $1.startSection }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("桂工课程助手")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                Text("第 \(appState.currentWeek) 周")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "location.fill")
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: Capsule())

            VStack(alignment: .leading, spacing: 8) {
                Text(appState.studentName.isEmpty ? "你好" : "你好，\(appState.studentName)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Text("今天 \(weekdayNames[todayWeekday]) · \(todayCourses.isEmpty ? "没有课" : "\(todayCourses.count) 门课")")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            if todayCourses.isEmpty {
                Spacer()
                Text("今天没有课")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(todayCourses) { course in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(course.name)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("\(course.teacher) · \(course.location)")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                Spacer()
                                Text("第 \(course.startSection)-\(course.endSection) 节")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
}
