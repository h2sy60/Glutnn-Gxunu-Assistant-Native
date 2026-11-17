import SwiftUI

/// 我的：显示当前学校、学号、姓名，提供退出登录。
struct MineView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                List {
                    Section {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appState.studentName.isEmpty ? "你好" : appState.studentName)
                                    .font(.headline)
                                Text("\(appState.school.displayName) · \(appState.studentId)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        HStack {
                            Text("当前周")
                            Spacer()
                            Text("第 \(appState.currentWeek) 周")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("学期")
                            Spacer()
                            Text("\(appState.year)-\(appState.year + 1) 学年 \(appState.semester)季学期")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        ShareLink("导出日志", item: AppLogger.shared.exportText())
                    } footer: {
                        Text("遇到问题时导出日志，方便定位。")
                    }

                    Section {
                        NavigationLink(destination: ScoreView()) {
                            Text("成绩查询")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            appState.logout()
                        } label: {
                            Text("退出登录")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
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

    /// 把成绩数组取成普通值，避免 ForEach(scores) 被解析成 Binding 集合。
    private var scores: [CourseScore] { appState.scores }

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
                List {
                    Section {
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
                    }

                    ForEach(scores) { score in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(score.courseName)
                                    .font(.headline)
                                Spacer()
                                Text(score.rawScore)
                                    .font(.headline)
                                    .foregroundStyle(score.score >= 60 ? .primary : .red)
                            }
                            Text("\(score.teacher.isEmpty ? "—" : score.teacher) · \(score.courseCategory.isEmpty ? "—" : score.courseCategory)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("学分 \(score.credit, specifier: "%.1f") · 绩点 \(score.gradePoint, specifier: "%.1f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await appState.refreshScores()
                }
            }
        }
        .navigationTitle("成绩")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.scores.isEmpty && appState.scoresError == nil {
                await appState.refreshScores()
            }
        }
    }
}
