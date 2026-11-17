import SwiftUI

/// 首页占位：顶部玻璃导航条 + 文案。登录 / 今日课表下一步做。
/// 背景由 WindowGroup 层的渐变提供（铺满全屏），这里只放内容。
struct HomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("桂工课程助手")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                Text("第 12 周")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "location.fill")
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: Capsule())

            Spacer()

            Text("首页占位 · 登录 / 今日课表下一步做")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }
}

#Preview {
    HomeView()
}
