import SwiftUI

struct MainView: View {
    @State private var selectedTopic: String? = "All Stories"
    @StateObject private var feedManager = FeedManager()
    
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
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                            .onTapGesture {
                                feedManager.fetchFeeds()
                            }
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.top, 40)
                    .padding(.horizontal, 30)
                    
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if feedManager.articles.isEmpty {
                                Text("No articles found or caching...")
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.top, 40)
                            } else {
                                ForEach(feedManager.articles) { article in
                                    ZStack(alignment: .bottomLeading) {
                                        // Image Background
                                        if let imageUrl = article.imageUrl, let url = URL(string: imageUrl) {
                                            AsyncImage(url: url) { image in
                                                image
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250)
                                                    .clipped()
                                            } placeholder: {
                                                Color.white.opacity(0.1)
                                                    .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250)
                                            }
                                        } else {
                                            Color.gray.opacity(0.1)
                                                .frame(maxWidth: .infinity, minHeight: 250)
                                        }
                                        
                                        // Gradient overlay for text readability
                                        LinearGradient(colors: [Color.clear, Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                                            .frame(height: 150)
                                        
                                        // Overlay info
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("LATEST UPDATE")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.white.opacity(0.6))
                                                .padding(.bottom, 2)
                                                
                                            Text(article.title)
                                                .font(.system(size: 20, weight: .bold, design: .default))
                                                .foregroundColor(.white)
                                                .lineLimit(2)
                                                .shadow(radius: 2)
                                                
                                            Text(article.description)
                                                .font(.system(size: 14))
                                                .foregroundColor(.white.opacity(0.8))
                                                .lineLimit(2)
                                        }
                                        .padding(20)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .cornerRadius(18)
                                    .padding(.horizontal, 30)
                                    .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                if feedManager.articles.isEmpty {
                    feedManager.fetchFeeds()
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
