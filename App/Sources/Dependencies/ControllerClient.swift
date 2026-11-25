import ComposableArchitecture
import Foundation

/// The controller layer, as the store sees it: connection events in, a few commands out.
struct ControllerClient: Sendable {
    var events: @Sendable () -> AsyncStream<ControllerEvent>
    var start: @Sendable () -> Void
    var disconnect: @Sendable (_ id: String) -> Void
    var setRawReportLogging: @Sendable (Bool) -> Void
}

/// The mapping engine, as the store sees it.
struct MappingEngineClient: Sendable {
    var update: @Sendable (MappingSnapshot) -> Void
    var previews: @Sendable () -> AsyncStream<InputPreview>
}

/// The long-lived objects behind the live clients: one engine, and either the real Bluetooth
/// central or the simulated controllers.
final class LiveRuntime: @unchecked Sendable {
    static let shared = LiveRuntime()

    let engine: MappingEngine
    let previews: AsyncStream<InputPreview>
    private let central: Switch2Central?
    private let simulated: SimulatedControllers?
    /// Set when `JOYMAPPER_EVENT_LOG` is: events and dictated text are recorded, not sent.
    private let recorder: FileRecordingPoster?

    private init() {
        let output: EventPoster
        if let path = ProcessInfo.processInfo.environment["JOYMAPPER_EVENT_LOG"] {
            Log.app.notice("Recording events to \(path) instead of posting them")
            let recorder = FileRecordingPoster(url: URL(filePath: path))
            self.recorder = recorder
            output = recorder
        } else {
            recorder = nil
            output = CGEventPoster()
        }
        engine = MappingEngine(poster: RoutingPoster(output: output))

        let (stream, continuation) = AsyncStream.makeStream(of: InputPreview.self, bufferingPolicy: .bufferingNewest(50))
        previews = stream
        engine.onPreview = { continuation.yield($0) }

        if let kinds = SimulatedControllers.kindsFromEnvironment() {
            simulated = SimulatedControllers(kinds: kinds, engine: engine)
            central = nil
        } else {
            central = Switch2Central(engine: engine)
            simulated = nil
        }
    }

    /// Pastes dictated text into the frontmost app, or records it in tests.
    func insertText(_ text: String) async {
        if let recorder {
            recorder.post(.insertText(text))
            return
        }
        await TextInserter.paste(text)
    }

    var controllerClient: ControllerClient {
        ControllerClient(
            events: { [self] in simulated?.events ?? central!.events },
            start: { [self] in
                simulated?.start()
                central?.start()
            },
            disconnect: { [self] id in
                simulated?.disconnect(id)
                central?.disconnect(id)
            },
            setRawReportLogging: { [self] isOn in central?.setRawReportLogging(isOn) }
        )
    }

    var engineClient: MappingEngineClient {
        MappingEngineClient(
            update: { [engine] in engine.update($0) },
            previews: { [previews] in previews }
        )
    }
}

/// Sends dictation actions from controller buttons to dictation, and everything else on.
struct RoutingPoster: EventPoster {
    let output: EventPoster

    func post(_ event: SyntheticEvent) {
        if case let .action(action, down) = event {
            DictationRuntime.shared.handle(action, down: down)
        }
        output.post(event)
    }
}

extension ControllerClient: DependencyKey {
    static var liveValue: ControllerClient { LiveRuntime.shared.controllerClient }

    static let testValue = ControllerClient(
        events: unimplemented("ControllerClient.events", placeholder: AsyncStream { $0.finish() }),
        start: unimplemented("ControllerClient.start"),
        disconnect: unimplemented("ControllerClient.disconnect"),
        setRawReportLogging: unimplemented("ControllerClient.setRawReportLogging")
    )
}

extension MappingEngineClient: DependencyKey {
    static var liveValue: MappingEngineClient { LiveRuntime.shared.engineClient }

    static let testValue = MappingEngineClient(
        update: unimplemented("MappingEngineClient.update"),
        previews: unimplemented("MappingEngineClient.previews", placeholder: AsyncStream { $0.finish() })
    )
}

extension DependencyValues {
    var controllers: ControllerClient {
        get { self[ControllerClient.self] }
        set { self[ControllerClient.self] = newValue }
    }

    var mappingEngine: MappingEngineClient {
        get { self[MappingEngineClient.self] }
        set { self[MappingEngineClient.self] = newValue }
    }
}
