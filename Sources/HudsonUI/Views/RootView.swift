import SwiftUI

/// Root scene content. This task renders a placeholder so the window opens and
/// can be screenshotted; the three-pane layout replaces this body in Task 11.
public struct RootView: View {
    @State private var model: AppModel?
    private let databaseURL: URL
    private let isDemo: Bool

    /// `isDemo` routes through `AppModel.demo()` (a fixed-path temp
    /// database, seeded with `DemoData` on first open) instead of opening
    /// `databaseURL` — used by `--demo`/`HUDSON_DEMO=1` for screenshots and
    /// manual QA without ever touching a real mailbox.
    public init(databaseURL: URL, isDemo: Bool = false) {
        self.databaseURL = databaseURL
        self.isDemo = isDemo
    }

    public var body: some View {
        ZStack {
            Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1A/255).ignoresSafeArea()
            Text("Hudson")
                .font(.system(size: 40, weight: .semibold, design: .serif))
                .foregroundStyle(Color(red: 0xEC/255, green: 0xEA/255, blue: 0xE4/255))
        }
        .frame(minWidth: 1040, minHeight: 680)
        .task {
            guard model == nil else { return }
            model = try? await (isDemo ? AppModel.demo() : AppModel(databaseURL: databaseURL))
        }
    }
}
