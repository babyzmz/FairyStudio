import SwiftUI

struct ContentView: View {
    @State private var model = CalcModel()

    var body: some View {
        VStack(spacing: 16) {
            Text(model.label)
                .font(.title)
            HStack {
                Button("- 单价") {
                    model.lessPrice()
                }
                Text("单价 \(model.price)")
                Button("+ 单价") {
                    model.morePrice()
                }
            }
            HStack {
                Button("- 数量") {
                    model.lessCount()
                }
                Text("数量 \(model.count)")
                Button("+ 数量") {
                    model.moreCount()
                }
            }
            HStack {
                Button("- 税率") {
                    model.lessTax()
                }
                Text("税率 \(model.taxPercent)%")
                Button("+ 税率") {
                    model.moreTax()
                }
            }
            Text("小计 \(model.subtotal)")
        }
        .padding()
    }
}
