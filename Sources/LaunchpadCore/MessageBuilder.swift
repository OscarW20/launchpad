import Foundation

/// Builds a bot's chat message from run events as they stream in.
public struct MessageBuilder: Sendable {
    public private(set) var message: ChatMessage
    public private(set) var sessionId: String?
    private var lastWasStep = false

    public init(botId: String?) {
        message = ChatMessage(role: .bot, botId: botId, status: .streaming)
    }

    public var isFinished: Bool { message.status != .streaming }

    /// The step currently running, for a live "working on…" line.
    public var activeStep: Step? { message.steps.last { $0.status == .running } }

    public mutating func apply(_ event: RunEvent) {
        guard !isFinished else { return }
        switch event {
        case .sessionStarted(let id):
            sessionId = id

        case .textDelta(let delta):
            if lastWasStep && !message.text.isEmpty && !message.text.hasSuffix("\n\n") {
                message.text += "\n\n"
            }
            message.text += delta
            lastWasStep = false

        case .text(let block):
            if !message.text.isEmpty { message.text += message.text.hasSuffix("\n") ? "\n" : "\n\n" }
            message.text += block
            lastWasStep = false

        case let .stepStarted(id, tool, title, detail):
            if let i = message.steps.firstIndex(where: { $0.id == id }) {
                message.steps[i].title = title
                message.steps[i].detail = detail
            } else {
                message.steps.append(Step(id: id, tool: tool, title: title, detail: detail))
            }
            lastWasStep = true

        case let .stepFinished(id, output, failed):
            if let i = message.steps.firstIndex(where: { $0.id == id }) {
                message.steps[i].output = output
                message.steps[i].status = failed ? .failed : .succeeded
            }

        case .cost(let usd):
            message.costUSD = usd

        case .finished(let resultText):
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let resultText {
                message.text = resultText
            }
            settleSteps(.succeeded)
            message.status = .done

        case .engineError(let raw):
            // Normally converted by the runner; handle it anyway.
            fail(RunFailure(kind: .unknown, message: raw))

        case .failed(let failure):
            fail(failure)

        case .stopped:
            settleSteps(.stopped)
            message.status = .stopped
        }
    }

    private mutating func fail(_ failure: RunFailure) {
        // Engines sometimes echo the error as reply text; don't show it twice.
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail = failure.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, detail.contains(text) {
            message.text = ""
        }
        settleSteps(.failed)
        message.failure = failure
        message.status = .failed
    }

    private mutating func settleSteps(_ status: Step.Status) {
        for i in message.steps.indices where message.steps[i].status == .running {
            message.steps[i].status = status
        }
    }
}
