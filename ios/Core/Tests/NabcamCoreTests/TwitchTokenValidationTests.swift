import XCTest
@testable import NabcamCore

final class TwitchTokenValidationTests: XCTestCase {
    private func claims(login: Any = "viewer", scopes: [String] = ["chat:read"], expires: Int = 3600) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["login": login, "user_id": "123", "scopes": scopes, "expires_in": expires])
    }
    func testValidReadScope() throws {
        XCTAssertNoThrow(try TwitchTokenValidation.check(claims(), username: "viewer"))
    }
    func testWrongUserMissingScopeAppTokenAndExpiredTokenRejected() throws {
        for data in [try claims(login: "other"), try claims(scopes: ["chat:edit"]),
                     try claims(login: NSNull()), try claims(expires: 0), try claims(expires: -1)] {
            XCTAssertThrowsError(try TwitchTokenValidation.check(data, username: "viewer"))
        }
    }
    func testMalformedAndOversizedClaimsRejected() {
        XCTAssertThrowsError(try TwitchTokenValidation.check(Data("{}".utf8), username: "viewer"))
        XCTAssertThrowsError(try TwitchTokenValidation.check(Data(repeating: 32, count: 8193), username: "viewer"))
    }
}
