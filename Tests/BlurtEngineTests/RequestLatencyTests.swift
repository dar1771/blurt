import Foundation
import Testing

@testable import BlurtEngine

@Suite("Request latency diagnostics")
struct RequestLatencyTests {
  @Test("Missing and inverted transaction dates are unknown, not zero")
  func missingDates() {
    let start = Date(timeIntervalSince1970: 100)
    #expect(RequestLatency.milliseconds(from: nil, to: start) == nil)
    #expect(RequestLatency.milliseconds(from: start, to: nil) == nil)
    #expect(RequestLatency.milliseconds(from: start, to: start.addingTimeInterval(-1)) == nil)
    #expect(RequestLatency.milliseconds(from: start, to: start.addingTimeInterval(2)) == 2_000)
  }

  @Test("Instrumentation preserves injected transport responses and failures")
  func preservesTransport() async throws {
    let request = URLRequest(url: URL(staticString: "https://example.invalid/test"))
    let transport = FakeHTTPTransport { received in
      #expect(received == request)
      return (429, Data("limited".utf8))
    }
    let (body, response) = try await transport.measuredData(for: request, stage: "stt", attempt: 2)
    #expect(body == Data("limited".utf8))
    #expect((response as? HTTPURLResponse)?.statusCode == 429)
    let failing = FakeHTTPTransport.failing(with: URLError(.cancelled))
    await #expect(throws: URLError(.cancelled)) {
      try await failing.measuredData(for: request, stage: "normalize")
    }
  }
}
