import SwiftUI

// MARK: - 课表：显示真实拉到的课程（按星期分组的简单列表）

struct ScheduleView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if appState.scheduleLoading && appState.courses.isEmpty {
                    ProgressView("正在拉取课表…")
                } else if appState.thisWeekCourses.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(appState.scheduleError ?? "本周没有课程")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重新拉取") {
                            Task { await appState.refreshSchedule() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(1...7, id: \.self) { weekday in
                            let dayCourses = appState.thisWeekCourses.filter { $0.weekday == weekday }
                            if !dayCourses.isEmpty {
                                Section(weekdayNames[weekday]) {
                                    ForEach(dayCourses) { course in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(course.name)
                                                .font(.headline)
                                            Text("第 \(course.startSection)-\(course.endSection) 节 · \(course.teacher)")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                            Text(course.location)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await appState.refreshSchedule()
                    }
                }
            }
            .navigationTitle("课表 · 第 \(appState.currentWeek) 周")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshSchedule() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(appState.scheduleLoading)
                }
            }
        }
    }
}

#Preview {
    ScheduleView()
        .environment(AppState())
}
