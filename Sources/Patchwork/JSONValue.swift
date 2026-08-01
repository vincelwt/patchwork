import Foundation
import PatchworkKit

/// The app and the shared package used to carry two structurally identical JSON trees, which
/// meant the runtime adapters could not live anywhere the daemon could reach them. There is now
/// one type; `JSONValue` stays as the app's name for it so call sites read unchanged.
typealias JSONValue = PiJSONValue
