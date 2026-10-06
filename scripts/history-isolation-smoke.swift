import BlurtEngine
import Foundation

/// The app-level test composition must start with an empty in-memory history,
/// even on a machine with existing or damaged production History.sqlite.
@main
struct HistoryIsolationSmoke {
  @MainActor static func main() async throws {
    let model = HistoryModel(testing: true)
    for _ in 0..<100 {
      if model.historyStore != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard let store = model.historyStore else { throw Failure.notPrepared }
    guard try await store.all().isEmpty else { throw Failure.personalHistoryReached }
    let record = DictationRecord(
      job: DictationJob(generation: 1), status: .ready, rawTranscript: "isolated test fixture")
    model.recordChanged(record)
    for _ in 0..<100 {
      if try await store.record(id: record.id) == record { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard try await store.all() == [record] else { throw Failure.fixtureNotPersisted }
    let second = HistoryModel(testing: true)
    for _ in 0..<100 {
      if second.historyStore != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard let secondStore = second.historyStore,
      try await secondStore.all().isEmpty
    else { throw Failure.testInstancesShareHistory }
    print("ok: app UI-test history isolation (empty initial store, own fixture roundtrip, independent test instances)")
  }

  enum Failure: Error {
    case notPrepared
    case personalHistoryReached
    case fixtureNotPersisted
    case testInstancesShareHistory
  }
}
