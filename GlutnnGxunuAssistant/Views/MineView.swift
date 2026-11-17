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

    /// 成绩数组存在 @State 里（普通值），.task 与 .onChange 再从 appState 同步。
    @State private var scores: [CourseScore] = []

    /// 临时：把成绩拼成纯文本展示。List/ForEach 在此页总被解析成 Binding
    ///（build 13–19 六次全挂），先拿掉列表，列表界面稍后单独修。
    private var scoresText: String {
        scores.map { "\($0.courseName)  \($0.rawScore)  \($0.teacher.isEmpty ? "—" : $0.teacher)" }.joined(separator: "\n")
    }

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

                    // 临时：成绩以纯文本展示（List/ForEach 在此页总被解析成 Binding，先拿掉）。
                    ScrollView {
                        Text(scoresText)
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
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
