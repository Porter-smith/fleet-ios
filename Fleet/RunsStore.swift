import Foundation
import Observation
import FleetKit

/// The sidebar's lists: runs that are working or wait on you, then every other thread
/// grouped by machine. Polled while on screen (the API has no list-wide stream).
@MainActor @Observable
final class RunsStore {
    struct Group: Identifiable {
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
    var query = ""

    init(client: FleetClient) { self.client = client }

    private static func latest(_ run: Run) -> Double { run.updatedAt ?? run.createdAt }

    private var visible: [Run] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = runs.sorted { Self.latest($0) > Self.latest($1) }
        guard !q.isEmpty else { return list }
        return list.filter { ($0.title ?? "").lowercased().contains(q) || ($0.cwd ?? "").lowercased().contains(q) }
    }

    /// "Running and waiting": runs mid-turn and runs that need you, the waiting ones first.
    var active: [Run] {
        visible.filter {
            let status = ChatThread.status(of: $0)
            return status == .running || status == .waiting
        }
        .sorted { (ChatThread.status(of: $0) == .waiting ? 0 : 1) < (ChatThread.status(of: $1) == .waiting ? 0 : 1) }
    }

    /// "Threads": the rest, by machine.
    var groups: [Group] {
        let activeIds = Set(active.map(\.id))
        let rest = visible.filter { !activeIds.contains($0.id) }
        let byMachine = Dictionary(grouping: rest, by: \.machineId)
        return byMachine.map { id, runs in
            let machine = machines.first { $0.id == id }
            return Group(id: id, name: machine?.name ?? id, machine: machine, runs: runs)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func machine(_ id: String) -> Machine? { machines.first { $0.id == id } }

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
