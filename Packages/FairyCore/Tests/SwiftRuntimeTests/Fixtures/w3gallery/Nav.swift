import SwiftUI

/// W3 导航与呈现画廊（fairy-run render 差分夹具；交互见 W3ViewTests）。
struct GalleryNav: View {
    @State private var path: [String] = []
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var answer = "none"
    var body: some View {
        NavigationStack(path: $path) {
            VStack {
                NavigationLink("Detail", value: "d1")
                NavigationLink(value: 42) { Text("Answer") }
                NavigationLink("About") { Text("about page") }
                Button("Sheet") { showSheet = true }
                Button("Alert") { showAlert = true }
                Text("answer \(answer) depth \(path.count)")
            }
            .navigationDestination(for: String.self) { s in
                Text("str \(s)")
            }
            .navigationDestination(for: Int.self) { i in
                Text("int \(i)")
            }
            .navigationTitle("Nav")
        }
        .sheet(isPresented: $showSheet) {
            Text("hello sheet")
        }
        .alert("Q", isPresented: $showAlert) {
            Button("Yes") { answer = "yes" }
            Button("No", role: .cancel) { answer = "no" }
        } message: {
            Text("pick one")
        }
    }
}
