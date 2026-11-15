import Foundation

/// The protocol's Actions ("perform actions": Selenium's ActionChains, WebdriverIO's `action`) as
/// the steps this driver makes with its own pointer, wheel and keyboard (docs/AUTOMATION.md,
/// "WebDriver"): the pointer moved onto an element or to a point — a hover —, the left button
/// pressed and let go where the pointer is — a click, a double click —, keys, the wheel, pauses.
///
/// A client sends its input sources side by side (a pointer's actions, a keyboard's, a wheel's),
/// padded with pauses so that the n-th action of each belongs to one tick. Here they are made one
/// after another, tick by tick, the sources in the order given: one hand on the mouse, then the
/// keys.
///
/// What this driver cannot make as a person's is refused before anything of the request is done,
/// each saying which: a move with the button held (a drag), another button than the left, a
/// touch or a pen, a click with a modifier key held, a button left held at the request's end,
/// the wheel sideways.
public enum WebDriverActions {
    public enum Origin: Equatable, Sendable {
        /// From the viewport's top left.
        case viewport
        /// From where the pointer is.
        case pointer
        /// From the middle of the element of this id.
        case element(String)
    }

    public enum Step: Equatable, Sendable {
        /// The pointer to `x`, `y` from `origin`.
        case move(Origin, x: Double, y: Double)
        /// The left button, where the pointer is.
        case press
        case release
        /// A key or a combination pressed, or characters typed.
        case key(WebDriverKeys.Stroke)
        /// The pointer to `x`, `y` from `origin`, then the wheel `deltaY` points down (up when negative).
        case scroll(Origin, x: Double, y: Double, deltaY: Double)
        case pause(TimeInterval)
    }

    /// No pause of a request is longer: a client's mistake in milliseconds must not hold a profile for a day.
    public static let longestPause: TimeInterval = 600
    /// Nor a request longer than this many steps.
    public static let maximumSteps = 2000

    /// The steps the body of "perform actions" asks for (`{"actions": [source…]}`).
    public static func steps(_ body: [String: Any]) throws -> [Step] {
        guard let given = body["actions"] as? [[String: Any]] else {
            throw WebDriverError.invalidArgument("actions is a list of input sources")
        }
        var sources: [(kind: String, actions: [[String: Any]])] = []
        for source in given {
            guard let kind = source["type"] as? String, ["pointer", "key", "wheel", "none"].contains(kind),
                  let actions = source["actions"] as? [[String: Any]] else {
                throw WebDriverError.invalidArgument("an input source has a type (pointer, key, wheel, none) and its actions")
            }
            if kind == "pointer" {
                let pointer = (source["parameters"] as? [String: Any])?["pointerType"] as? String ?? "mouse"
                guard pointer == "mouse" else {
                    throw WebDriverError.unsupported("a \(pointer) pointer is not part of this driver: its pointer is a mouse")
                }
            }
            sources.append((kind, actions))
        }
        var steps: [Step] = []
        var held: [String] = []
        var buttonDown = false
        for tick in 0..<(sources.map { $0.actions.count }.max() ?? 0) {
            var pause: TimeInterval = 0
            for source in sources where tick < source.actions.count {
                let action = source.actions[tick]
                guard let type = action["type"] as? String else { throw WebDriverError.invalidArgument("an action has a type") }
                switch (source.kind, type) {
                case (_, "pause"):
                    pause = max(pause, try number(action["duration"], "duration", atLeast: 0) / 1000)
                case ("pointer", "pointerMove"):
                    guard !buttonDown else {
                        throw WebDriverError.unsupported("a move with the button held (a drag) is not part of this driver")
                    }
                    steps.append(.move(try origin(action["origin"], pointerAllowed: true),
                                       x: try number(action["x"], "x"), y: try number(action["y"], "y")))
                case ("pointer", "pointerDown"):
                    guard try number(action["button"], "button") == 0 else {
                        throw WebDriverError.unsupported("only the left button is part of this driver")
                    }
                    guard held.isEmpty else {
                        throw WebDriverError.unsupported("a click with \(held.joined(separator: "+")) held is not part of this driver")
                    }
                    if !buttonDown { steps.append(.press) }
                    buttonDown = true
                case ("pointer", "pointerUp"), ("pointer", "pointerCancel"):
                    if buttonDown { steps.append(.release) }
                    buttonDown = false
                case ("key", "keyDown"), ("key", "keyUp"):
                    guard let value = action["value"] as? String, value.count == 1, let character = value.first else {
                        throw WebDriverError.invalidArgument("a key action's value is one key")
                    }
                    switch try WebDriverKeys.key(character) {
                    case .modifier(let name):
                        held.removeAll { $0 == name }
                        if type == "keyDown" { held.append(name) }
                    case .named(let name):
                        if type == "keyDown" { steps.append(.key(.press((held + [name]).joined(separator: "+")))) }
                    case .character(let typed):
                        guard type == "keyDown" else { break }
                        if !held.isEmpty {
                            steps.append(.key(.press((held + [String(typed)]).joined(separator: "+"))))
                        } else if case .key(.type(let run))? = steps.last {
                            // Characters one after another are one run of typing.
                            steps[steps.count - 1] = .key(.type(run + String(typed)))
                        } else {
                            steps.append(.key(.type(String(typed))))
                        }
                    case .null:
                        if type == "keyDown" { held = [] }
                    }
                case ("wheel", "scroll"):
                    guard try number(action["deltaX"], "deltaX") == 0 else {
                        throw WebDriverError.unsupported("the wheel sideways is not part of this driver: it scrolls up and down")
                    }
                    steps.append(.scroll(try origin(action["origin"], pointerAllowed: false),
                                         x: try number(action["x"], "x"), y: try number(action["y"], "y"),
                                         deltaY: try number(action["deltaY"], "deltaY")))
                default:
                    throw WebDriverError.invalidArgument("\(type) is not an action of a \(source.kind) source")
                }
            }
            if pause > 0 { steps.append(.pause(min(pause, longestPause))) }
            guard steps.count <= maximumSteps else {
                throw WebDriverError.invalidArgument("more than \(maximumSteps) actions in one request")
            }
        }
        guard !buttonDown else {
            throw WebDriverError.unsupported("a button left held at the end of the actions (click and hold) is not part of this driver")
        }
        return steps
    }

    /// A number of an action, 0 when it is not given; one that is not a finite number — or below
    /// `atLeast` — is an invalid argument.
    private static func number(_ value: Any?, _ name: String, atLeast: Double = -.infinity) throws -> Double {
        guard let value, !(value is NSNull) else { return 0 }
        let number = (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
        guard let number, number.isFinite, number >= atLeast else {
            throw WebDriverError.invalidArgument("\(name) is a number")
        }
        return number
    }

    /// Where a move or a scroll is measured from: "viewport" (also when none is given), "pointer"
    /// where a pointer may say so, or an element (`{"element-6066-…": id}`).
    private static func origin(_ value: Any?, pointerAllowed: Bool) throws -> Origin {
        guard let value, !(value is NSNull) else { return .viewport }
        if let name = value as? String {
            if name == "viewport" { return .viewport }
            if name == "pointer", pointerAllowed { return .pointer }
        } else if let element = (value as? [String: Any])?[WebDriverRoute.elementKey] as? String, !element.isEmpty {
            return .element(element)
        }
        throw WebDriverError.invalidArgument("origin is \"viewport\"\(pointerAllowed ? ", \"pointer\"" : "") or an element")
    }
}
