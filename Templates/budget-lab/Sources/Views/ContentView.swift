import SwiftUI

struct BudgetLabView: View {
    @State private var model = BudgetModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("预算推演").font(.title)
                Stepper("团队：\(model.people) 人", value: $model.people, in: 1...20)
                HStack {
                    Button("− 单价") { if model.dayRate > 400 { model.dayRate -= 100 } }
                    Text("人天单价 \(model.dayRate) 元")
                    Button("+ 单价") { if model.dayRate < 3000 { model.dayRate += 100 } }
                }
                Stepper("工期：\(model.weeks) 周", value: $model.weeks, in: 1...24)
                HStack {
                    Button("− 利润率") { if model.marginPercent > 0 { model.marginPercent -= 5 } }
                    Text("利润率 \(model.marginPercent)%")
                    Button("+ 利润率") { if model.marginPercent < 60 { model.marginPercent += 5 } }
                }
                Divider()
                Text("成本 \(model.cost(p: model.people)) 元").font(.headline)
                Text("报价 \(model.quoted(p: model.people)) 元").font(.headline)
                Divider()
                Text("敏感度：人数 ±1").font(.callout)
                HStack {
                    Text("\(model.people - 1) 人")
                    Spacer()
                    Text("\(model.quoted(p: max(1, model.people - 1))) 元").font(.callout)
                }
                HStack {
                    Text("\(model.people) 人（当前）")
                    Spacer()
                    Text("\(model.quoted(p: model.people)) 元").font(.callout)
                }
                HStack {
                    Text("\(model.people + 1) 人")
                    Spacer()
                    Text("\(model.quoted(p: model.people + 1)) 元").font(.callout)
                }
                Text("公式版本 v1：成本 = 人 × 单价 × 5 天 × 周数").font(.caption)
            }
            .padding()
        }
    }
}
