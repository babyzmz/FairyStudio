import SwiftUI

@main
struct FairyStudioApp: App {
    @State private var studio = StudioModel()
    @State private var aiStatus = AIStatusModel()

    var body: some Scene {
        WindowGroup {
            RootView(studio: studio, aiStatus: aiStatus)
        }
    }
}

/// M0 根界面：两个页签。选中夹具引擎时，顶部始终显示「夹具引擎：非真实执行」横幅。
struct RootView: View {
    let studio: StudioModel
    let aiStatus: AIStatusModel

    var body: some View {
        TabView {
            Tab("运行实验", systemImage: "play.rectangle") {
                withFixtureBanner(RunLabView(studio: studio))
            }
            Tab("AI 状态", systemImage: "sparkles") {
                withFixtureBanner(AIStatusView(model: aiStatus))
            }
        }
    }

    /// 横幅放在每个页签内容的顶部（占据布局空间），不覆盖运行/停止工具条。
    /// 注：挂在 TabView 上的 safeAreaInset 在 iOS 26 不会推开页签内容（实测会遮住工具条）。
    private func withFixtureBanner(_ content: some View) -> some View {
        VStack(spacing: 0) {
            if studio.engineChoice.isFixture {
                FixtureBanner()
            }
            content
        }
    }
}

/// 夹具引擎横幅：持久可见，不可关闭。
struct FixtureBanner: View {
    var body: some View {
        Label("夹具引擎：非真实执行", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color.yellow)
            .accessibilityIdentifier("fixture.banner")
    }
}
