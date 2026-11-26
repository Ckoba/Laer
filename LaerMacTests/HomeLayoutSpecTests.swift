import Foundation
import Testing
@testable import Laer

struct HomeLayoutSpecTests {
    @Test func fallsBackToAutomaticPlacementForAnOversizedSavedRow() throws {
        let json = """
        {"items":[{"block":"due","positions":{
            "1":{"column":0,"row":\(Int.max)},
            "2":{"column":1,"row":3}
        }}]}
        """
        let layout = try JSONDecoder().decode(HomeLayout.self, from: Data(json.utf8))

        #expect(HomeLayout.arrange(layout.items, columns: 1).first?.row == 0)
        #expect(HomeLayout.arrange(layout.items, columns: 2).first?.row == 3)
    }
}
