import SwiftUI

/// `.unsupported` 节点的可见占位：显示符号、能力目录 ID 与「运行时尚不支持」。绝不渲染为空白。
public struct UnsupportedNodeView: View {
    public let symbol: String
    public let capabilityID: String

    public init(symbol: String, capabilityID: String) {
        self.symbol = symbol
        self.capabilityID = capabilityID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("运行时尚不支持")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(verbatim: symbol)
                .font(.body.monospaced())
            Text(verbatim: capabilityID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("运行时尚不支持 \(symbol)"))
        .accessibilityIdentifier("bridge.unsupported.\(capabilityID)")
    }
}

/// 无效参数标记（样式名未知、尺寸非法等）。
struct InvalidParameterBadge: View {
    let description: String

    var body: some View {
        Label {
            Text(verbatim: description)
                .lineLimit(1)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.caption2)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(Color.red.opacity(0.85), in: Capsule())
        .accessibilityLabel(Text("无效参数 \(description)"))
        .allowsHitTesting(false)
    }
}
