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

/// M0 根界面：两个页签。
struct RootView: View {
    let studio: StudioModel
    let aiStatus: AIStatusModel

    var body: some View {
        TabView {
            Tab("运行实验", systemImage: "play.rectangle") {
                RunLabView(studio: studio)
            }
            Tab("AI 状态", systemImage: "sparkles") {
                AIStatusView(model: aiStatus)
            }
        }
    }
}
