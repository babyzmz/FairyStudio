struct ReportModel {
    var customer = ""
    var project = ""
    var devices = 8
    var result = "验收通过"
    var note = ""

    func text() -> String {
        var lines: [String] = []
        lines.append("交付报告")
        lines.append("客户：\(customer.isEmpty ? "（未填）" : customer)")
        lines.append("项目：\(project.isEmpty ? "（未填）" : project)")
        lines.append("设备数量：\(Int(devices)) 台")
        lines.append("验收结论：\(result)")
        if note != "" {
            lines.append("备注：\(note)")
        }
        lines.append("建议回访周期：\(max(30, devices * 5)) 天")
        return lines.joined(separator: "\n")
    }
}
