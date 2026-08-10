import Foundation
import Testing
@testable import Rapid

@Suite("Memory-load confirmation request isolation (#1463)")
struct MemoryLoadConfirmationQueueTests {
    private func warning(_ alias: String) -> ModelSizing.MemoryWarning {
        ModelSizing.MemoryWarning(
            alias: alias,
            hfPath: nil,
            isAutoRespawn: false,
            severity: .unsafe,
            footprintGB: 24,
            freeGB: 4,
            totalGB: 32
        )
    }

    @Test("overlapping loads receive only their own decisions")
    func decisionsAreRequestScoped() {
        var queue = MemoryLoadConfirmationQueue()
        let requestA = UUID()
        let requestB = UUID()
        let warningA = warning("model-a")
        let warningB = warning("model-b")

        queue.enqueue(warning: warningA, requestID: requestA)
        queue.enqueue(warning: warningB, requestID: requestB)

        #expect(queue.currentWarning?.id == warningA.id)
        let staleResolution = queue.resolveCurrent(warning: warningB, decision: .confirmed(sequence: 99))
        let cancelledA = queue.resolveCurrent(warning: warningA, decision: .cancelled)
        let decisionA = queue.takeDecision(for: requestA)
        let prematureDecisionB = queue.takeDecision(for: requestB)
        #expect(staleResolution == false)
        #expect(cancelledA == true)
        #expect(decisionA == .cancelled)
        #expect(prematureDecisionB == nil)

        #expect(queue.currentWarning?.id == warningB.id)
        let confirmedB = queue.resolveCurrent(warning: warningB, decision: .confirmed(sequence: 7))
        let decisionB = queue.takeDecision(for: requestB)
        #expect(confirmedB == true)
        #expect(decisionB == .confirmed(sequence: 7))
        #expect(queue.currentWarning == nil)
        queue.completeConfirmedLaunch(warningID: warningB.id)
        #expect(queue.currentWarning == nil)
    }

    @Test("same-alias loads remain distinct requests")
    func duplicateAliasesRemainDistinct() {
        var queue = MemoryLoadConfirmationQueue()
        let requestA = UUID()
        let requestB = UUID()
        let warningA = warning("same-model")
        let warningB = warning("same-model")

        queue.enqueue(warning: warningA, requestID: requestA)
        queue.enqueue(warning: warningB, requestID: requestB)
        #expect(warningA.id != warningB.id)

        let confirmedA = queue.resolveCurrent(warning: warningA, decision: .confirmed(sequence: 1))
        let decisionA = queue.takeDecision(for: requestA)
        let decisionB = queue.takeDecision(for: requestB)
        #expect(confirmedA)
        #expect(decisionA == .confirmed(sequence: 1))
        #expect(decisionB == nil)
        #expect(queue.currentWarning == nil)
        queue.completeConfirmedLaunch(warningID: warningA.id)
        #expect(queue.currentWarning?.id == warningB.id)
    }

    @Test("direct starts do not retain an unconsumed decision")
    func directStartDecisionIsNotRetained() {
        var queue = MemoryLoadConfirmationQueue()
        let warning = warning("picker-start")
        queue.enqueue(warning: warning, requestID: nil)

        let confirmed = queue.resolveCurrent(warning: warning, decision: .confirmed(sequence: 3))
        #expect(confirmed)
        #expect(queue.currentWarning == nil)
        queue.completeConfirmedLaunch(warningID: warning.id)
        #expect(queue.currentWarning == nil)
    }

    @Test("a cancelled waiter leaves the visible prompt usable without leaking a result")
    func abandonedWaiterDoesNotLeakDecision() {
        var queue = MemoryLoadConfirmationQueue()
        let request = UUID()
        let warning = warning("cancelled-chat")
        queue.enqueue(warning: warning, requestID: request)

        queue.abandonWaiter(request)
        #expect(queue.currentWarning?.id == warning.id)
        let confirmed = queue.resolveCurrent(warning: warning, decision: .confirmed(sequence: 4))
        #expect(confirmed)
        queue.completeConfirmedLaunch(warningID: warning.id)
        let decision = queue.takeDecision(for: request)
        #expect(decision == nil)
    }

    @Test("next prompt waits for both confirmed launch completion and result consumption")
    func confirmedLaunchSerializesNextPrompt() {
        var queue = MemoryLoadConfirmationQueue()
        let requestA = UUID()
        let requestB = UUID()
        let warningA = warning("model-a")
        let warningB = warning("model-b")
        queue.enqueue(warning: warningA, requestID: requestA)
        queue.enqueue(warning: warningB, requestID: requestB)

        let confirmedA = queue.resolveCurrent(warning: warningA, decision: .confirmed(sequence: 1))
        #expect(confirmedA)
        #expect(queue.currentWarning == nil)
        let delayedCancel = queue.resolveCurrent(warning: warningA, decision: .cancelled)
        #expect(delayedCancel == false)
        queue.completeConfirmedLaunch(warningID: warningA.id)
        #expect(queue.currentWarning == nil)
        let decisionA = queue.takeDecision(for: requestA)
        #expect(decisionA == .confirmed(sequence: 1))
        #expect(queue.currentWarning?.id == warningB.id)
    }

    @Test("cancellation after confirmation drains the retained decision")
    func confirmedThenAbandonedDoesNotLeakDecision() {
        var queue = MemoryLoadConfirmationQueue()
        let request = UUID()
        let warning = warning("confirmed-then-cancelled")
        queue.enqueue(warning: warning, requestID: request)

        let confirmed = queue.resolveCurrent(warning: warning, decision: .confirmed(sequence: 8))
        #expect(confirmed)
        queue.abandonWaiter(request)
        let decision = queue.takeDecision(for: request)
        #expect(decision == nil)
        queue.completeConfirmedLaunch(warningID: warning.id)
        #expect(queue.currentWarning == nil)
    }
}
