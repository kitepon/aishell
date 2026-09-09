import Foundation
import Security
import XCTest
@testable import AIShellCore

final class NoninteractiveKeychainTests: XCTestCase {
    func testFileKeychainInteractionIsDisabled() throws {
        XCTAssertEqual(NoninteractiveKeychain.configure(), errSecSuccess)
        var allowed: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue)
    }
}
