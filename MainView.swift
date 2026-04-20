import SwiftUI

struct MainView: View {
    @State private var selectedTopic: String? = "All Stories"
    
    let topics = ["All Stories", "World", "Tech", "Culture", "Science", "Politics"]
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(topics, id: \.self, selection: $selectedTopic) { topic in
                NavigationLink(value: topic) {
                    Text(topic)
                        .font(.system(size: 14, weight: .medium, design: .default))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            // Apply native macOS blur for sidebar material behind window
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea())
        } detail: {
            // Main Content Area
            ZStack {
                // Base background gradient for depth
                LinearGradient(colors: [Color.black, Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(selectedTopic?.uppercased() ?? "DAILY FLOW")
                            .font(.system(size: 24, weight: .bold, design: .default))
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.top, 40)
                    .padding(.horizontal, 30)
                    
                    Spacer()
                    
                    Text("RSS Parser & Caching Layer Coming Soon")
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                    
                    Spacer()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// SwiftUI bridge for NSVisualEffectView to achieve Glassmorphism natively
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
