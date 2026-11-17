import SwiftUI

/// 课表：浅色不透明页面占位（子页面风格）。
struct ScheduleView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("课表占位")
                        .font(.headline)
                    Text("登录 + 课表解析下一步做")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("课表")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ScheduleView()
}
