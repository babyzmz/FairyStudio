import Foundation

/// `.mojoproject` 文档包的布局常量。包是一个目录，后缀 `.mojoproject`。
/// 包内顶层：`project.json` + `Sources/ Resources/ Documents/ Data/ Tests/`。
public enum ProjectLayout {
    /// 文档包后缀（不含点）。
    public static let packageExtension = "mojoproject"
    /// 清单文件名。
    public static let manifestFileName = "project.json"
    /// 源码根。
    public static let sources = "Sources"
    /// 资源根（图片等只读资源，W1 仅占位）。
    public static let resources = "Resources"
    /// 文档根（说明、回滚记录之外的用户文档）。
    public static let documents = "Documents"
    /// 业务数据根（W4 数据雏形使用）。
    public static let data = "Data"
    /// 测试根（项目内测试，W1 仅占位）。
    public static let tests = "Tests"

    /// 包内全部顶层内容目录。
    public static let contentRoots = [sources, resources, documents, data, tests]
}
