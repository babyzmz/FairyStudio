import Foundation
import Observation
import RuntimeContracts

/// 「运行实验」页的状态：两个源码文件、当前引擎选择与 RunCoordinator。
@MainActor
@Observable
final class StudioModel {
    struct EditableFile: Identifiable, Hashable {
        let id: FileID
        var path: String
        var contents: String
    }

    var files: [EditableFile]
    var selectedFileID: FileID
    private(set) var engineChoice: EngineChoice
    let coordinator: RunCoordinator

    init(engineChoice: EngineChoice = EngineChoice.fromLaunchArguments() ?? .swiftRuntime) {
        let files = SampleProgram.files.map { EditableFile(id: $0.id, path: $0.path, contents: $0.contents) }
        self.files = files
        self.selectedFileID = files[0].id
        self.engineChoice = engineChoice
        self.coordinator = RunCoordinator(engine: engineChoice.makeEngine())
    }

    var program: ProgramSource {
        ProgramSource(moduleName: "Experiment", files: files.map { SourceFile(id: $0.id, path: $0.path, contents: $0.contents) })
    }

    func selectEngine(_ choice: EngineChoice) {
        guard choice != engineChoice else { return }
        engineChoice = choice
        coordinator.replaceEngine(choice.makeEngine())
    }

    func run() {
        coordinator.run(program)
    }

    func stop() {
        coordinator.stop()
    }

    func binding(for fileID: FileID) -> EditableFile? {
        files.first { $0.id == fileID }
    }

    func updateContents(of fileID: FileID, to contents: String) {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else { return }
        files[index].contents = contents
    }
}

/// M0 示例：两个互相引用的 Swift 文件（由真正的 SwiftRuntime 执行；夹具引擎会忽略它们）。
enum SampleProgram {
    static let files: [SourceFile] = [
        SourceFile(id: FileID("file-content-view"), path: "Sources/ContentView.swift", contents: """
        import SwiftUI

        struct ContentView: View {
            @State private var counter = Counter()

            var body: some View {
                VStack(spacing: 16) {
                    Text("Count: \\(counter.value)")
                        .font(.largeTitle)
                    Button("+1") {
                        counter.increment()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        """),
        SourceFile(id: FileID("file-counter"), path: "Sources/Counter.swift", contents: """
        struct Counter {
            private(set) var value = 0

            mutating func increment() {
                value += 1
            }
        }
        """),
    ]
}
