import Foundation
import Network

/// One frame per connection, with bounded asynchronous operations even if Network never delivers a callback.
struct ClipboardSyncConnection: Sendable {
  let connection: NWConnection
  let queue: DispatchQueue
  var operationTimeout: TimeInterval = 20
  var deadline: DispatchTime?

  func start(timeout: TimeInterval = 20) async throws {
    let _: Void = try await perform(timeout: timeout) { resolve in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: resolve(.success(()))
        case .failed, .cancelled: resolve(.failure(ClipboardSyncError.connectionFailed))
        default: break
        }
      }
      connection.start(queue: queue)
    }
  }

  func send(_ data: Data) async throws {
    let _: Void = try await perform(timeout: operationTimeout) { resolve in
      connection.send(
        content: data, contentContext: .defaultMessage, isComplete: true,
        completion: .contentProcessed { error in
          if error != nil {
            resolve(.failure(ClipboardSyncError.connectionFailed))
          } else {
            resolve(.success(()))
          }
        })
    }
  }

  func receiveFrame(maximumBodySize: Int = ClipboardSyncLimits.maximumEnvelopeBytes) async throws -> Data {
    let header = try await receiveExactly(ClipboardSyncCodec.headerBytes)
    let bodySize = try ClipboardSyncCodec.bodySize(header: header)
    guard bodySize <= maximumBodySize else { throw ClipboardSyncError.tooLarge }
    return header + (try await receiveExactly(bodySize))
  }

  private func receiveExactly(_ count: Int) async throws -> Data {
    var result = Data()
    while result.count < count {
      let remaining = count - result.count
      let chunk: Data = try await perform(timeout: operationTimeout) { resolve in
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 64 * 1024)) { data, _, _, error in
          if error != nil {
            resolve(.failure(ClipboardSyncError.connectionFailed))
          } else if let data, !data.isEmpty {
            resolve(.success(data))
          } else {
            resolve(.failure(ClipboardSyncError.invalidFrame))
          }
        }
      }
      result.append(chunk)
    }
    return result
  }

  private func perform<Value: Sendable>(
    timeout: TimeInterval,
    _ operation: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
  ) async throws -> Value {
    let remaining: TimeInterval
    if let deadline {
      let now = DispatchTime.now().uptimeNanoseconds
      guard deadline.uptimeNanoseconds > now else {
        connection.cancel()
        throw ClipboardSyncError.timedOut
      }
      remaining = min(timeout, Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
    } else {
      remaining = timeout
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
        let pending = Mutex<CheckedContinuation<Value, Error>?>(continuation)
        queue.asyncAfter(deadline: .now() + remaining) { [weak connection] in
          let timedOut = pending.withLock { value in
            guard let continuation = value else { return false }
            value = nil
            continuation.resume(throwing: ClipboardSyncError.timedOut)
            return true
          }
          if timedOut { connection?.cancel() }
        }
        operation { result in
          pending.withLock { value in
            value?.resume(with: result)
            value = nil
          }
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }
}
