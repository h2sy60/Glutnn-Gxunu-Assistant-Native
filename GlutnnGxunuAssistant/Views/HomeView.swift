import SwiftUI

/// 首页：深色壁纸主页面（占位渐变）+ 顶部玻璃导航。
/// 玻璃只在导航层（顶栏药丸），内容层不放玻璃——按 Apple HIG。
struct HomeView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.14),
                    Color(red: 0.10, green: 0.13, blue: 0.24),
                    Color(red: 0.07, green: 0.09, blue: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                // 顶部玻璃导航药丸
                HStack(spacing: 8) {
                    Text("桂工课程助手")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("第 12 周")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 16)

                Spacer()

                Text("首页占位 · 登录 / 今日课表下一步做")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()
            }
            .padding(.top, 8)
        }
    }
}

#Preview {
    HomeView()
}
