import SwiftUI
import FoundationAI
import ProjectContracts
import ProjectCore
import RuntimeContracts

/// W1 `ProjectLibrary` 对助手协议的适配（W2.md 交接项）。
extension ProjectLibrary: AssistantProjectLibrary {
    public var displayName: String { "我的作品" }
}

// 助手面板宿主：W1 工作区预留槽位调用的唯一入口（W1 并行开发，按此签名预留位置）。
// 不持有文件句柄；诊断/控制台只读 coordinator 数据。
public struct AssistantPanelHost: View {
    @State private var session: AssistantSession
    private var onLocate: (FileID, Int) -> Void

    init(project: any ProjectAccess, coordinator: RunCoordinator, library: ProjectLibraryStub?,
         initialPrompt: String = "", onLocate: @escaping (FileID, Int) -> Void = { _, _ in }) {
        _session = State(initialValue: AssistantSession(project: project, coordinator: coordinator,
                                                        library: library, initialPrompt: initialPrompt,
                                                        settings: .shared,
                                                        agent: FoundationModelsAgentRunner()))
        self.onLocate = onLocate
    }

    public var body: some View {
        ChatView(session: session, onLocate: onLocate)
    }
}
