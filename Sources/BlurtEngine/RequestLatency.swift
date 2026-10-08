import Foundation
import os

/// Local diagnostics only: no request headers, audio, transcript, or file paths.
enum RequestLatency {
  @TaskLocal static var jobID: UUID?
  static let logger = HostIdentity.current.logger("PipelineLatency")

  static func stage(
    _ name: String, since start: ContinuousClock.Instant, bytes: Int = 0, job: UUID? = jobID
  ) {
    let elapsed = (ContinuousClock.now - start).milliseconds
    logger.info(
      "latency job=\(job?.uuidString ?? "none", privacy: .public) stage=\(name, privacy: .public) ms=\(elapsed, privacy: .public) bytes=\(bytes, privacy: .public)"
    )
  }

  static func retry(attempt: Int, delay: TimeInterval) {
    logger.info(
      "latency job=\(jobID?.uuidString ?? "none", privacy: .public) stage=stt-retry attempt=\(attempt, privacy: .public) delaySeconds=\(delay, privacy: .public)"
    )
  }

  /// Missing or inverted dates stay unknown, rather than suggesting a zero-cost stage.
  static func milliseconds(from start: Date?, to end: Date?) -> Double? {
    guard let start, let end, end >= start else { return nil }
    return end.timeIntervalSince(start) * 1_000
  }
}

extension HTTPTransport {
  func measuredData(
    for request: URLRequest, stage: String, attempt: Int = 1
  ) async throws -> (Data, URLResponse) {
    let delegate = RequestLatencyDelegate(stage: stage, attempt: attempt)
    let start = ContinuousClock.now
    var status = 0
    defer {
      let elapsed = (ContinuousClock.now - start).milliseconds
      RequestLatency.logger.info(
        "latency job=\(delegate.job, privacy: .public) request=\(delegate.id, privacy: .public) stage=\(stage, privacy: .public) attempt=\(attempt, privacy: .public) status=\(status, privacy: .public) totalMs=\(elapsed, privacy: .public) bodyBytes=\(request.httpBody?.count ?? 0, privacy: .public)"
      )
    }
    let result: (Data, URLResponse)
    if let session = self as? URLSession {
      result = try await session.data(for: request, delegate: delegate)
    } else {
      // Injected transports retain their behavior; network timestamps are unavailable.
      result = try await data(for: request)
    }
    status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
    return result
  }
}

/// Immutable identifiers can safely be read on URLSession's delegate queue.
private final class RequestLatencyDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  let id = UUID().uuidString
  let job = RequestLatency.jobID?.uuidString ?? "none"
  let stage: String
  let attempt: Int

  init(stage: String, attempt: Int) {
    self.stage = stage
    self.attempt = attempt
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    for (index, transaction) in metrics.transactionMetrics.enumerated() {
      func ms(_ start: Date?, _ end: Date?) -> String {
        RequestLatency.milliseconds(from: start, to: end).map { String(format: "%.0f", $0) } ?? "n/a"
      }
      RequestLatency.logger.info(
        """
        latency job=\(self.job, privacy: .public) request=\(self.id, privacy: .public) stage=\(self.stage, privacy: .public) \
        attempt=\(self.attempt, privacy: .public) transaction=\(index + 1, privacy: .public) \
        reused=\(transaction.isReusedConnection, privacy: .public) proxy=\(transaction.isProxyConnection, privacy: .public) \
        dnsMs=\(ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate), privacy: .public) \
        connectMs=\(ms(transaction.connectStartDate, transaction.connectEndDate), privacy: .public) \
        tlsMs=\(ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate), privacy: .public) \
        uploadMs=\(ms(transaction.requestStartDate, transaction.requestEndDate), privacy: .public) \
        waitMs=\(ms(transaction.requestEndDate, transaction.responseStartDate), privacy: .public) \
        downloadMs=\(ms(transaction.responseStartDate, transaction.responseEndDate), privacy: .public) \
        bodyBytesSent=\(transaction.countOfRequestBodyBytesSent, privacy: .public)
        """)
    }
  }
}
