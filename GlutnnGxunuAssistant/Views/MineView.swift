import SwiftUI

/// 我的（Flutter 版形态）：壁纸 + 玻璃卡片。
struct MineView: View {
    @Environment(AppState.self) private var appState

    /// 玻璃卡片容器。
    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 顶栏：Hi! 名字（Flutter mine.dart 同款）
                        Text(appState.studentName.isEmpty ? "Hi!" : "Hi! \(appState.studentName)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                            .padding(.top, 60)
                            .padding(.horizontal, 20)

                        VStack(spacing: 12) {
                            // 个人信息卡片
                            glassCard {
                                HStack {
                                    Image(systemName: "person.circle.fill")
                                        .font(.largeTitle)
                                        .foregroundStyle(.white.opacity(0.9))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(appState.studentName.isEmpty ? "你好" : appState.studentName)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                        Text("\(appState.school.displayName) · \(appState.studentId)")
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    Spacer()
                                    Button("更换账号") {
                                        appState.switchAccount()
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .glassEffect(.regular, in: Capsule())
                                }
                            }

                            // 学期信息卡片
                            glassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("当前周")
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text("第 \(appState.currentWeek) 周")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    HStack {
                                        Text("学期")
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text("\(appState.year)-\(appState.year + 1) 学年 \(appState.semester)季学期")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                            }

                            // 成绩查询
                            NavigationLink(destination: ScoreView()) {
                                HStack {
                                    Image(systemName: "chart.bar.fill")
                                        .foregroundStyle(.white)
                                    Text("成绩查询")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                            }

                            // 导出日志
                            glassCard {
                                HStack {
                                    ShareLink("导出日志", item: AppLogger.shared.exportText())
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text("遇到问题时导出日志，方便定位。")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }

                            // 退出登录
                            Button(role: .destructive) {
                                appState.logout()
                            } label: {
                                Text("退出登录")
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 14)
                            }
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 140)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }
}

#Preview {
    MineView()
        .environment(AppState())
}


#Preview {
    ScoreView()
        .environment(AppState())
}

// MARK: - 成绩页：列表 + 平均绩点/平均分（与 Flutter 版口径一致）

struct ScoreView: View {
    @Environment(AppState.self) private var appState

    /// 成绩数组存在 @State 里（普通值），.task 与 .onChange 再从 appState 同步。
    /// 注意：List 用 $scores（Binding）——本页的 List/ForEach 若传普通数组，
    /// Swift 6 会把它解析成 Binding 重载而报错（build 13–19 六次全挂）；
    /// 直接传 Binding 反而对上编译器要的重载，行内用 .wrappedValue 取值。
    @State private var scores: [CourseScore] = []

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if appState.scoresLoading && appState.scores.isEmpty {
                ProgressView("正在拉取成绩…")
            } else if let error = appState.scoresError, appState.scores.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") {
                        Task { await appState.refreshScores() }
                    }
                }
            } else if appState.scores.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无成绩")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("平均绩点")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f", gradePointAverage(scores)))
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("平均分")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f", averageScore(scores)))
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        Text("\(scores.count) 门课")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // 成绩列表（真实列表行，不及格标红，下拉刷新）。
                    List($scores, id: \.id) { $score in
                        let s = $score.wrappedValue
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.courseName)
                                    .font(.headline)
                                Text("\(s.teacher.isEmpty ? "—" : s.teacher) · \(s.courseCategory.isEmpty ? "—" : s.courseCategory)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("学分 \(s.credit, specifier: "%.1f") · 绩点 \(s.gradePoint, specifier: "%.2f")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(s.rawScore)
                                .font(.headline)
                                .foregroundStyle(s.score < 60 && s.score > 0 ? .red : .primary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await appState.refreshScores()
                    }
                }
            }
        }
        .navigationTitle("成绩")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.scores.isEmpty && appState.scoresError == nil {
                await appState.refreshScores()
            }
            scores = appState.scores
        }
        .onChange(of: appState.scores.count) { _, _ in
            scores = appState.scores
        }
    }
}

/// 考试安排页（build 43 新增）。与 ScoreView 同款结构：
/// List 用 $exams（Binding），避免 Swift 6 把普通数组解析成 Binding 重载。
struct ExamsView: View {
    @Environment(AppState.self) private var appState

    @State private var exams: [ExamItem] = []

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if appState.examsLoading && appState.exams.isEmpty {
                ProgressView("正在拉取考试安排…")
            } else if let error = appState.examsError, appState.exams.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新拉取") {
                        Task { await appState.refreshExams() }
                    }
                }
            } else if appState.exams.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无考试安排")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                List($exams, id: \.id) { $exam in
                    let e = $exam.wrappedValue
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.courseName)
                            .font(.headline)
                        if !e.examName.isEmpty {
                            Text(e.examName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(e.time)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(e.location)
                            if !e.seatNumber.isEmpty {
                                Text("· 座位 \(e.seatNumber)")
                            }
                            if !e.campus.isEmpty {
                                Text("· \(e.campus)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await appState.refreshExams()
                }
            }
        }
        .navigationTitle("考试")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.exams.isEmpty && appState.examsError == nil {
                await appState.refreshExams()
            }
            exams = appState.exams
        }
        .onChange(of: appState.exams.count) { _, _ in
            exams = appState.exams
        }
    }
}
