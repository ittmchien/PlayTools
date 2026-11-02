//
//  EmulatedControllerComboEngine.swift
//  PlayTools
//

import Foundation

// Controller combos: pure key -> controller input state machine. Held keys press their own `Buttons` input,
// a held key set presses all inputs of its combo, and every input goes out as its synthetic usage
// (syntheticUsageBase + input index), so a combo and a plain key sharing an input never fight over it
struct EmulatedControllerComboEngine {
    static let syntheticUsageBase = 0x10000
    // Controller combos: leftShoulder, rightShoulder, leftTrigger, rightTrigger input indexes
    private static let modifierInputs: Set<Int> = [8, 9, 18, 19]

    // Controller combos: what wins when a combo's keys also have their own `Buttons` input (plist `Priority`)
    enum Priority: String {
        // The combo takes over: its keys are consumed and their own inputs released (default)
        case combo = "Combo"
        // Own inputs win: the combo applies only when none of its keys has an own input
        case keys = "Keys"
        // Both apply: the combo fires and its keys keep their own inputs (consumes nothing)
        case both = "Both"
    }

    struct Combo: Equatable {
        let keys: Set<Int>
        let inputs: Set<Int>
        let priority: Priority

        init(keys: Set<Int>, inputs: Set<Int>, priority: Priority = .combo) {
            self.keys = keys
            self.inputs = inputs
            self.priority = priority
        }
    }

    struct KeyEvent: Equatable {
        let usage: Int
        let isDown: Bool
    }

    let buttons: [Int: Int]
    let combos: [Combo]
    // Combos by key count descending, ties in file order
    private let prioritizedCombos: [Combo]
    private let comboKeys: Set<Int>
    private var heldKeys: Set<Int> = []
    private var pressedInputs: Set<Int> = []

    // Controller combos: `buttons` holds the real keys only (HID usage -> input index), never synthetic entries
    init(buttons: [Int: Int], combos: [Combo]) {
        self.buttons = buttons
        self.combos = combos
        prioritizedCombos = combos.enumerated()
            .sorted { lhs, rhs in
                lhs.element.keys.count != rhs.element.keys.count
                    ? lhs.element.keys.count > rhs.element.keys.count
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
        comboKeys = combos.reduce(into: Set<Int>()) { keys, combo in keys.formUnion(combo.keys) }
    }

    static func syntheticUsage(for input: Int) -> Int {
        syntheticUsageBase + input
    }

    // Controller combos: keys outside every combo and `Buttons` stay with Apple's handler
    func handles(key: Int) -> Bool {
        buttons[key] != nil || comboKeys.contains(key)
    }

    // Controller combos: a repeated down or an up of a key that is not held changes nothing and emits nothing
    mutating func update(key: Int, isDown: Bool) -> [KeyEvent] {
        guard handles(key: key) else { return [] }
        if isDown {
            heldKeys.insert(key)
        } else {
            heldKeys.remove(key)
        }
        return press(desiredInputs())
    }

    // Controller combos: ups for every pressed input, used before the engine is replaced (no stuck buttons)
    mutating func releaseAll() -> [KeyEvent] {
        heldKeys.removeAll()
        return press([])
    }

    // Controller combos: fully held combos apply largest first; only `.combo` ones consume their keys and skip
    // keys already consumed, `.keys` ones apply only without own inputs, `.both` always apply.
    // Remaining held keys add their own input
    private func desiredInputs() -> Set<Int> {
        var consumedKeys = Set<Int>()
        var desired = Set<Int>()
        for combo in prioritizedCombos where combo.keys.isSubset(of: heldKeys) {
            switch combo.priority {
            case .combo:
                guard combo.keys.isDisjoint(with: consumedKeys) else { continue }
                consumedKeys.formUnion(combo.keys)
            case .keys:
                guard combo.keys.allSatisfy({ buttons[$0] == nil }) else { continue }
            case .both:
                break
            }
            desired.formUnion(combo.inputs)
        }
        for key in heldKeys.subtracting(consumedKeys) {
            if let input = buttons[key] {
                desired.insert(input)
            }
        }
        return desired
    }

    // Controller combos: diff against what is pressed now, ups before downs. Games read L1/R1/L2/R2 as modifiers
    // (L2 + Triangle != Triangle), so downs press modifiers first and ups release them last
    private mutating func press(_ desired: Set<Int>) -> [KeyEvent] {
        let ups = Self.ordered(pressedInputs.subtracting(desired), modifiersFirst: false)
            .map { KeyEvent(usage: Self.syntheticUsage(for: $0), isDown: false) }
        let downs = Self.ordered(desired.subtracting(pressedInputs), modifiersFirst: true)
            .map { KeyEvent(usage: Self.syntheticUsage(for: $0), isDown: true) }
        pressedInputs = desired
        return ups + downs
    }

    // Controller combos: input order with modifiers in front or behind the rest, each group by input index
    private static func ordered(_ inputs: Set<Int>, modifiersFirst: Bool) -> [Int] {
        inputs.sorted { lhs, rhs in
            let lhsRank = modifierInputs.contains(lhs) == modifiersFirst ? 0 : 1
            let rhsRank = modifierInputs.contains(rhs) == modifiersFirst ? 0 : 1
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs < rhs
        }
    }

    #if DEBUG
    // Controller combos: assert-based check of the engine scenarios from the spec, run with the remap self-check
    static func selfCheck() {
        let shiftKey = 225, wKey = 26, rKey = 21, spaceKey = 44
        let buttonA = 4, buttonX = 6, leftShoulder = 8, rightShoulder = 9, leftStickUp = 10, leftTrigger = 18

        // The order the engine emits them in: modifiers first on press, last on release
        let rComboDowns = [leftShoulder, rightShoulder, buttonX]
        let rComboUps = [buttonX, leftShoulder, rightShoulder]
        var engine = EmulatedControllerComboEngine(
            buttons: [shiftKey: leftTrigger, wKey: leftStickUp, rKey: rightShoulder],
            combos: [
                Combo(keys: [rKey], inputs: Set(rComboDowns)),
                Combo(keys: [shiftKey, wKey], inputs: [buttonA])
            ])
        assert(!engine.handles(key: spaceKey), "Keys outside Buttons and combos must pass through")
        assert(engine.update(key: spaceKey, isDown: true).isEmpty, "Unhandled keys must emit nothing")

        assert(engine.update(key: rKey, isDown: true) == rComboDowns.map(pressed),
               "A single-key combo must press all its inputs")
        assert(engine.update(key: rKey, isDown: true).isEmpty, "A repeated down must be a no-op")
        assert(engine.update(key: rKey, isDown: false) == rComboUps.map(released),
               "Releasing a single-key combo must release all its inputs")

        assert(engine.update(key: shiftKey, isDown: true) == [pressed(leftTrigger)], "Shift alone must press its L2")
        assert(engine.update(key: wKey, isDown: true) == [released(leftTrigger), pressed(buttonA)],
               "Completing Shift+W must release L2 and press A without touching the stick")
        assert(engine.update(key: wKey, isDown: false) == [released(buttonA), pressed(leftTrigger)],
               "Releasing W while holding Shift must press L2 again")
        assert(engine.update(key: shiftKey, isDown: false) == [released(leftTrigger)],
               "Releasing Shift must release L2")

        var layered = EmulatedControllerComboEngine(
            buttons: [:],
            combos: [Combo(keys: [shiftKey], inputs: [buttonX]), Combo(keys: [shiftKey, wKey], inputs: [buttonA])])
        assert(layered.update(key: shiftKey, isDown: true) == [pressed(buttonX)], "The subset combo applies alone")
        assert(layered.update(key: wKey, isDown: true) == [released(buttonX), pressed(buttonA)],
               "A superset combo must beat its subset regardless of file order")
        assert(layered.releaseAll() == [released(buttonA)], "releaseAll must release every pressed input")
        assert(layered.update(key: wKey, isDown: false).isEmpty, "Held state must be empty after releaseAll")

        // Modifier L2 goes down before Triangle and comes up after it, whatever the input indexes say
        let triangleKey = 30, buttonTriangle = 7
        var modifierCombo = EmulatedControllerComboEngine(
            buttons: [:], combos: [Combo(keys: [triangleKey], inputs: [buttonTriangle, leftTrigger])])
        assert(modifierCombo.update(key: triangleKey, isDown: true) == [pressed(leftTrigger), pressed(buttonTriangle)],
               "A combo must press its modifier before the other inputs")
        assert(modifierCombo.update(key: triangleKey, isDown: false)
                == [released(buttonTriangle), released(leftTrigger)],
               "A combo must release its modifier after the other inputs")

        prioritySelfCheck()
    }

    // Controller combos: assert-based check of the three Priority modes on Shift (own L2) + W (own stick up) -> A
    private static func prioritySelfCheck() {
        let shiftKey = 225, wKey = 26
        let buttonA = 4, buttonX = 6, leftStickUp = 10, leftTrigger = 18
        let ownButtons = [shiftKey: leftTrigger, wKey: leftStickUp]
        func chordEngine(_ priority: Priority, buttons: [Int: Int]) -> EmulatedControllerComboEngine {
            EmulatedControllerComboEngine(
                buttons: buttons, combos: [Combo(keys: [shiftKey, wKey], inputs: [buttonA], priority: priority)])
        }

        var keysFirst = chordEngine(.keys, buttons: ownButtons)
        assert(keysFirst.update(key: shiftKey, isDown: true) == [pressed(leftTrigger)], "Keys: Shift presses L2")
        assert(keysFirst.update(key: wKey, isDown: true) == [pressed(leftStickUp)],
               "Keys: own inputs must win and the combo must not fire")
        var keysUnmapped = chordEngine(.keys, buttons: [:])
        assert(keysUnmapped.update(key: shiftKey, isDown: true).isEmpty, "Keys: a partial chord presses nothing")
        assert(keysUnmapped.update(key: wKey, isDown: true) == [pressed(buttonA)],
               "Keys: a combo whose keys have no own input must fire")

        var both = chordEngine(.both, buttons: ownButtons)
        assert(both.update(key: shiftKey, isDown: true) == [pressed(leftTrigger)], "Both: Shift presses L2")
        assert(both.update(key: wKey, isDown: true) == [pressed(buttonA), pressed(leftStickUp)],
               "Both: the combo must fire while its keys keep their own inputs")

        var bothBesideCombo = EmulatedControllerComboEngine(
            buttons: ownButtons,
            combos: [
                Combo(keys: [shiftKey, wKey], inputs: [buttonA], priority: .both),
                Combo(keys: [shiftKey], inputs: [buttonX])
            ])
        assert(bothBesideCombo.update(key: shiftKey, isDown: true) == [pressed(buttonX)],
               "Combo: Shift's combo takes over its own L2")
        assert(bothBesideCombo.update(key: wKey, isDown: true) == [pressed(buttonA), pressed(leftStickUp)],
               "Both: must neither consume keys nor block a Combo-mode combo")
    }

    // Controller combos: expected synthetic events of an input, for the self-checks
    private static func pressed(_ input: Int) -> KeyEvent {
        KeyEvent(usage: syntheticUsage(for: input), isDown: true)
    }

    private static func released(_ input: Int) -> KeyEvent {
        KeyEvent(usage: syntheticUsage(for: input), isDown: false)
    }
    #endif
}
