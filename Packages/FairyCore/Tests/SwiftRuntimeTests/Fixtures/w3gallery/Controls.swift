import SwiftUI

/// W3 控件画廊（fairy-run render 差分夹具；对应 W3ViewTests 的单测）。
struct GalleryControls: View {
    @State private var speed = 50.0
    @State private var count = 3
    @State private var flavor = "choc"
    @State private var name = ""
    var body: some View {
        Form {
            Section("Tune", footer: "step 5, range 0...10") {
                Slider(value: $speed, in: 0...100, step: 5)
                Stepper("Count", value: $count, in: 0...10)
                Picker("Flavor", selection: $flavor) {
                    ForEach(["van", "choc", "mint"], id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Name", text: $name)
            }
            Section {
                ScrollView(.horizontal) {
                    HStack {
                        Image(systemName: "star")
                        Text("speed \(speed) count \(count) \(flavor) \(name)")
                    }
                }
            }
        }
        .navigationTitle("Controls")
    }
}
