import Testing
@testable import SwingDuet

struct PhaseSetTests {
    @Test(arguments: [0.0, 0.01, 0.1, 0.2, 3.0])
    func fallbackFitsTheActualVideo(_ duration: Double) {
        let phases = PhaseSet.fallback(duration: duration)
        let times = SwingPhase.allCases.map { phases.time(of: $0) }
        #expect(times.allSatisfy { (0...duration).contains($0) })
        #expect(times == times.sorted())
        if duration > 0 { #expect(Set(times).count == 4) }
    }

    @Test(arguments: [0.0, 0.01, 0.1, 0.2, 3.0])
    func sanitizingKeepsAllPhasesInTheVideo(_ duration: Double) {
        var phases = PhaseSet(address: 8, top: -1, impact: 10, finish: 0)
        phases.sanitize(duration: duration)
        let times = SwingPhase.allCases.map { phases.time(of: $0) }
        #expect(times.allSatisfy { (0...duration).contains($0) })
        #expect(times == times.sorted())
        if duration > 0 { #expect(Set(times).count == 4) }
    }

    @Test(arguments: [0.01, 0.1, 3.0])
    func editingShortVideosNeverReversesPhases(_ duration: Double) {
        for phase in SwingPhase.allCases {
            for target in [-1.0, 100.0] {
                var phases = PhaseSet.fallback(duration: duration)
                phases.assign(phase, to: target, duration: duration)
                let times = SwingPhase.allCases.map { phases.time(of: $0) }
                #expect(times.allSatisfy { (0...duration).contains($0) })
                #expect(times == times.sorted())
                #expect(Set(times).count == 4)
            }
        }
    }
}
