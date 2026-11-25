import ComposableArchitecture
import Foundation

/// A button or a stick direction: anything a binding can hang off.
enum BindingTarget: Hashable, Sendable {
    case button(ControllerButton)
    case stick(StickDirection)

    var displayName: String {
        switch self {
        case let .button(button): button.displayName
        case let .stick(direction): direction.displayName
        }
    }

    /// For accessibility identifiers: "a", "stick-up".
    var identifier: String {
        switch self {
        case let .button(button): button.rawValue
        case let .stick(direction): "stick-\(direction.rawValue)"
        }
    }
}

/// The sheet that edits one binding: pick a key from a list or record one, add modifiers, or
/// choose a mouse button.
@Reducer
struct BindingEditorFeature {
    @ObservableState
    struct State: Equatable {
        var target: BindingTarget
        var controllerName: String
        var binding: KeyBinding
        var searchText = ""
        /// While true, the next key pressed in the sheet becomes the binding.
        var isRecording = false

        var matchingKeys: [(code: Int, name: String)] {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return KeyNames.all }
            return KeyNames.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.target == rhs.target
                && lhs.controllerName == rhs.controllerName
                && lhs.binding == rhs.binding
                && lhs.searchText == rhs.searchText
                && lhs.isRecording == rhs.isRecording
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case keySelected(Int?)
        case modifierToggled(Modifiers)
        case mouseButtonSelected(MouseButton?)
        case recordTapped
        case keyRecorded(code: Int, modifiers: Modifiers)
        case clearTapped
        case saveTapped
        case cancelTapped
        case delegate(Delegate)

        @CasePathable
        enum Delegate: Equatable {
            case save(BindingTarget, KeyBinding)
        }
    }

    @Dependency(\.dismiss) var dismiss

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case let .keySelected(code):
                state.binding.keyCode = code
                return .none

            case let .modifierToggled(modifier):
                if state.binding.modifiers.contains(modifier) {
                    state.binding.modifiers.remove(modifier)
                } else {
                    state.binding.modifiers.insert(modifier)
                }
                return .none

            case let .mouseButtonSelected(button):
                state.binding.mouseButton = button
                return .none

            case .recordTapped:
                state.isRecording.toggle()
                return .none

            case let .keyRecorded(code, modifiers):
                guard state.isRecording else { return .none }
                state.isRecording = false
                state.binding.keyCode = code
                state.binding.modifiers = modifiers
                Log.app.info("Recorded \(state.binding.displayString) for \(state.target.identifier)")
                return .none

            case .clearTapped:
                state.binding = .none
                return .none

            case .saveTapped:
                let target = state.target
                let binding = state.binding
                return .run { send in
                    await send(.delegate(.save(target, binding)))
                    await dismiss()
                }

            case .cancelTapped:
                return .run { _ in await dismiss() }

            case .delegate:
                return .none
            }
        }
    }
}
