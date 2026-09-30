import SwiftUI

// DesignSystem（页面重构 P1）：克制的表面/文字/间距/动作 token。
// 原则（计划 §10）：内容区安静、工具层清楚；颜色为设计起点，动态语义色优先；
// 不大面积玻璃化、不做卡通装饰；可爱仅限微交互。

enum DS {
    // MARK: - 间距（4/8/12/16/24/32 基数）

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - 圆角

    enum Radius {
        static let card: CGFloat = 22       // 作品卡 20–24 起点
        static let composer: CGFloat = 20   // 输入器约 20
        static let control: CGFloat = 10    // 密集控件小圆角
    }

    // MARK: - 表面（设计起点；语义色优先，最终以对比度实测为准）

    enum Surface {
        static func workbench(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(red: 0.063, green: 0.067, blue: 0.078)   // #101114
                            : Color(red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
        }

        static func content(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(red: 0.106, green: 0.114, blue: 0.133)   // #1B1D22
                            : .white
        }

        static func secondary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(red: 0.145, green: 0.157, blue: 0.188)   // #252830
                            : Color(red: 0.933, green: 0.941, blue: 0.957)   // #EEF0F4
        }
    }

    // MARK: - 布局

    enum Layout {
        static let assistantMinWidth: CGFloat = 320
        static let assistantIdealWidth: CGFloat = 360
        static let stageMinWidth: CGFloat = 480
        /// 卡片网格最小列宽（计划建议 240–280pt）。
        static let libraryCardMinWidth: CGFloat = 250
    }

    // MARK: - 微交互（120–250ms；Reduce Motion 由系统材质与调用方处理）

    enum Motion {
        static let quick: Animation = .easeOut(duration: 0.18)
        static let press: Animation = .spring(response: 0.25, dampingFraction: 0.7)
    }
}

/// 主舞台与助手的宽度分配（计划 §4.1：主舞台约 65–72%，助手 28–35%）。
enum WorkspaceWidths {
    /// 可用宽度 → (舞台宽, 助手宽)。空间不足时优先保舞台，助手收起到最小值。
    static func split(available: CGFloat) -> (stage: CGFloat, assistant: CGFloat) {
        let assistant = min(380, max(DS.Layout.assistantMinWidth, available * 0.32))
        let stage = max(DS.Layout.stageMinWidth, available - assistant)
        return (stage, available - stage)
    }
}
