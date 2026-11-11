import Foundation
import Testing

@testable import HostRuntime

/// Settings ▸ General's Device Names: each board's three names, and preferredName following the saved style.
struct BoardNameTests {
    @Test func everyBoardHasItsOwnNameInEachStyle() {
        #expect(Board.n72.name(.marketing) == "iPod touch (2nd generation)")
        #expect(Board.n72.name(.model) == "iPod2,1")
        #expect(Board.n72.name(.abbreviated) == "iPod 2G")
        for style in Board.NameStyle.allCases {
            let names = Board.allCases.map { board in
                board.name(style)
            }
            #expect(Set(names).count == Board.allCases.count, "no two boards share a \(style) name: \(names)")
        }
    }

    @Test func preferredNameFollowsTheSetting() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: Board.NameStyle.key)
        }
        defaults.removeObject(forKey: Board.NameStyle.key)
        #expect(Board.k48.preferredName == "iPad", "the marketing name by default")
        defaults.set(Board.NameStyle.abbreviated.rawValue, forKey: Board.NameStyle.key)
        #expect(Board.k48.preferredName == "iPad 1")
        defaults.set(Board.NameStyle.model.rawValue, forKey: Board.NameStyle.key)
        #expect(Board.k48.preferredName == "iPad1,1")
    }
}
