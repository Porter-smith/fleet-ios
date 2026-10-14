import Foundation
import XCTest
@testable import FleetKit

/// Fixtures are real responses from the Fleet dev server (`bun scripts/dev-fleet.ts`),
/// saved with curl, so these tests check the models against the API as it is. They
/// ship in FleetKit's `Demo/` folder, where the demo mode serves them too.
enum Fixture {
    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        try XCTUnwrap(Demo.fixture(name, ext), "missing fixture \(name).\(ext)")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}
