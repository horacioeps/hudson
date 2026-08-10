import Foundation
import Testing
@testable import Store

@Test func defaultDatabaseURLIsUnderApplicationSupportHudson() {
    let url = HudsonDatabase.defaultDatabaseURL
    #expect(url.lastPathComponent == "hudson.sqlite")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Hudson")
    #expect(url.path.contains("Application Support"))
}
