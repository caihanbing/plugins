import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("App Server protocol")
struct AppServerProtocolTests {
    @Test("JSONL framing supports split CRLF input")
    func jsonlFramerHandlesSplitAndCRLFMessages() {
        var framer = JSONLFramer()
        #expect(framer.append(Data(#"{"id":0}"#.utf8)).isEmpty)

        let lines = framer.append(Data("\r\n{\"id\":1}\n".utf8))
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == #"{"id":0}"#)
        #expect(String(decoding: lines[1], as: UTF8.self) == #"{"id":1}"#)
    }

    @Test("Rate-limit responses decode")
    func parsesRateLimitResponse() {
        let data = Data(#"""
        {
          "id": 6,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": {"usedPercent": 25, "windowDurationMins": 15, "resetsAt": 1730947200}
            }
          }
        }
        """#.utf8)

        guard case let .rateLimitsResponse(id, result) = AppServerMessageParser.parse(data) else {
            Issue.record("Expected a rate-limits response")
            return
        }
        #expect(id == 6)
        #expect(result.rateLimits?.primary?.remainingPercent == 75)
    }

    @Test("Real-time notifications decode")
    func parsesRealtimeNotification() {
        let data = Data(#"""
        {
          "method": "account/rateLimits/updated",
          "params": {
            "rateLimits": {
              "limitId": "codex",
              "primary": {"usedPercent": 31, "windowDurationMins": 15, "resetsAt": 1730948100}
            }
          }
        }
        """#.utf8)

        guard case let .rateLimitsUpdated(bucket) = AppServerMessageParser.parse(data) else {
            Issue.record("Expected a real-time update")
            return
        }
        #expect(bucket.primary?.remainingPercent == 69)
    }

    @Test("Malformed JSON yields a recoverable error")
    func malformedJSONReturnsError() {
        guard case .error = AppServerMessageParser.parse(Data("not-json".utf8)) else {
            Issue.record("Expected a parsing error")
            return
        }
    }
}
