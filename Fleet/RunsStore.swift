import Foundation
import Observation
import FleetKit

/// The runs list: every run the token can see, grouped by machine, polled while on screen.
/// (The API has no list-wide stream; each run has its own, used by the chat.)
@MainActor @Observable
final class RunsStore {
    struct Section: Identifiable {
        let id: String
        let name: String
        let machine: Machine?
        let runs: [Run]
    }

    let client: FleetClient
    private(set) var runs: [Run] = []
    private(set) var machines: [Machine] = []
    private(set) var loaded = false
    private(set) var error: String?
    var showAll = false

    init(client: FleetClient) { self.client = client }

    var sections: [Section] {
        let visible = showAll ? runs : runs.filter(\.isActive)
        let byMachine = Dictionary(grouping: visible, by: \.machineId)
        return byMachine.map { id, runs in
            let machine = machines.first { $0.id == id }
            let sorted = runs.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            return Section(id: id, name: machine?.name ?? id, machine: machine, runs: sorted)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var needsYou: Int { runs.filter { $0.isActive && $0.needsYou }.count }

    func refresh() async {
        do {
            runs = try await client.runs(limit: 200)
            if let machines = try? await client.machines() { self.machines = machines }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Refreshes every 4 s until the task is cancelled (the list leaves the screen).
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(4))
        }
    }
}
