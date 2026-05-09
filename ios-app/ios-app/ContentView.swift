import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone")
                .imageScale(.large)
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Hello, iOS!")
                .font(.largeTitle)
                .bold()

            Text("Собрано через GitHub Actions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
