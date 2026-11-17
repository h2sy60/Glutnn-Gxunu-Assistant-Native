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
