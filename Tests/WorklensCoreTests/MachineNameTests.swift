import Foundation
import Testing
@testable import WorklensCore

@Suite("MachineName")
struct MachineNameTests {
    @Test("the first run stamps the data directory")
    func firstRun() throws {
        let state = AppStateStore(try Database.inMemory())
        #expect(MachineName.record(in: state, current: "Studio") == .firstRun(name: "Studio"))
        #expect(try state.get(MachineName.stateKey) == "Studio")
    }

    @Test("the same Mac says nothing")
    func sameMac() throws {
        let state = AppStateStore(try Database.inMemory())
        MachineName.record(in: state, current: "Studio")
        let again = MachineName.record(in: state, current: "Studio")
        #expect(again == .same(name: "Studio"))
        #expect(again.message == nil)
    }

    @Test("a second Mac is named, and told what to do instead")
    func secondMac() throws {
        let state = AppStateStore(try Database.inMemory())
        MachineName.record(in: state, current: "Studio")

        let moved = MachineName.record(in: state, current: "Laptop")
        #expect(moved == .different(recorded: "Studio", current: "Laptop"))
        let message = try #require(moved.message)
        #expect(message.contains("Studio"))
        #expect(message.contains("Laptop"))
        #expect(message.contains("DATA_DIR"))
    }

    @Test("the row is restamped, so a renamed Mac says it once and two Macs say it every launch")
    func restamped() throws {
        let state = AppStateStore(try Database.inMemory())
        MachineName.record(in: state, current: "Studio")
        MachineName.record(in: state, current: "Laptop")

        // Renamed: the second launch under the new name is quiet.
        #expect(MachineName.record(in: state, current: "Laptop") == .same(name: "Laptop"))
        // Two Macs taking turns: each launch finds the other's name and says so again.
        #expect(MachineName.record(in: state, current: "Studio").message != nil)
        #expect(MachineName.record(in: state, current: "Laptop").message != nil)
    }

    @Test("this Mac always has a name to record")
    func currentIsNeverEmpty() {
        #expect(!MachineName.current.isEmpty)
    }
}
