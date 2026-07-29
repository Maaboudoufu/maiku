import MaikuKit
import SwiftUI

/// Plain `EnvironmentKey` rather than the `@Environment(Type.self)` sugar:
/// `AppEnvironment`'s own stored properties never change after launch, so it
/// does not need `@Observable` — only `coordinator`, which is `@Observable`
/// already and stays reactive however a view reaches it.
private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppEnvironment? = nil
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment? {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
