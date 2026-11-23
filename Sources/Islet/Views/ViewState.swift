import SwiftUI

/// Drop-in replacement for `@State`. The Command Line Tools SDK ships SwiftUI's `@State`
/// as a macro whose compiler plugin only comes with Xcode, so we wrap `State` ourselves.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
