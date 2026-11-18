import Foundation
import XCTest
@testable import WordLinks

final class ChatGPTErrorTests: XCTestCase {
    func testQuotaCreditAndRateFailuresAreNotConfusedByTheSameHTTPStatus() throws {
        for (code, expected) in [
            ("subscription_sharing_usage_limit_exceeded", ChatGPTError.usageLimit),
            ("insufficient_quota", .insufficientCredits),
            ("rate_limit_exceeded", .rateLimited)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "secret upstream details"]])
            XCTAssertEqual(ChatGPTError.fromHTTP(status: 429, data: data), expected)
            XCTAssertFalse(expected.localizedDescription.contains("secret"))
        }
        XCTAssertEqual(ChatGPTError.fromHTTP(status: 429, data: Data()), .rateLimited)
    }

    func testPolicyFailuresDoNotInviteEndlessLoginAndTemporaryErrorsDoNotExpireSessions() throws {
        for (status, body, expected) in [
            (403, #"{"error":{"code":"subscription_sharing_user_not_eligible"}}"#, ChatGPTError.notEligible),
            (403, #"{"error":{"code":"subscription_sharing_route_not_supported"}}"#, .unsupportedRequest),
            (503, #"{"detail":"private service diagnostics"}"#, .serviceUnavailable),
            (400, #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"model"}}"#, .modelUnavailable),
            (400, #"{"error":{"code":"refresh_token_invalid"}}"#, .loginExpired)
        ] {
            XCTAssertEqual(ChatGPTError.fromHTTP(status: status, data: Data(body.utf8)), expected)
        }
        XCTAssertEqual(ChatGPTError.notEligible.recovery, .manageUsage)
        XCTAssertEqual(ChatGPTError.missingPlanPermission.recovery, .authorize)
        XCTAssertEqual(ChatGPTError.loginExpired.recovery, .signIn)
        XCTAssertEqual(ChatGPTError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ChatGPTError.from(URLError(.timedOut)), .timedOut)
    }
}
