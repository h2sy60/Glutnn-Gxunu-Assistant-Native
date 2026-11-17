import SwiftUI

/// 我的：浅色不透明页面占位。
struct MineView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("我的占位")
                        .font(.headline)
                    Text("登录 / 名字 / 设置下一步做")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    MineView()
}
