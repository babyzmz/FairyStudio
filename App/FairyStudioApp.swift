import SwiftUI
import ProjectCore
import SwiftRuntime

@main
struct FairyStudioApp: App {
    /// 作品库：Documents/Projects（W1 项目存储）。
    private let library = ProjectLibrary(
        documentsURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!,
        currentRuntimeVersion: SwiftRuntimeEngine.version.description)

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
        }
    }
}
