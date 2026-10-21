import SwiftUI

@main
struct YTViewerApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}

enum ViewerColor {
    static let background = Color(red: 0.071, green: 0.078, blue: 0.094)
    static let raised = Color(red: 0.122, green: 0.133, blue: 0.157)
    static let ink = Color(red: 0.957, green: 0.945, blue: 0.918)
    static let muted = Color(red: 0.604, green: 0.584, blue: 0.549)
    static let accent = Color(red: 0.894, green: 0.631, blue: 0.353)
    static let danger = Color(red: 0.863, green: 0.412, blue: 0.333)
}
