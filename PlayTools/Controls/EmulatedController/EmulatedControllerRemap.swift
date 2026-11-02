//
//  EmulatedControllerRemap.swift
//  PlayTools
//

import Foundation
import GameController

// Controller emulation mapping: merges PlayCover's per-app key layout into the mapping Apple feeds
// GCKeyboardAndMouseEmulatedController, and live-applies edits to the file while the game runs
@objc public final class EmulatedControllerRemap: NSObject {
    private static let enabledKey = "Enabled"
    private static let buttonsKey = "Buttons"
    private static let validInputIndices = 0...24
    private static let reloadDebounce = DispatchTimeInterval.milliseconds(200)
    private static let emulatedControllerClassName = "GCKeyboardAndMouseEmulatedController"
    private static let mappingIvarName = "_mapping"
    private static let objectTypeEncodingPrefix = "@"
    private static let setupButtonsSelector = NSSelectorFromString("setupButtons")
    // Controller combos: plist keys of the optional `Combos` array of {Keys, Inputs, Priority} entries
    private static let combosKey = "Combos"
    private static let comboKeysKey = "Keys"
    private static let comboInputsKey = "Inputs"
    private static let comboPriorityKey = "Priority"

    private static let directoryURL = URL(
        fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover"
    ).appendingPathComponent("EmulatedController")
    private static let fileURL = directoryURL
        .appendingPathComponent(PlaySettings.shared.bundleIdentifier)
        .appendingPathExtension("plist")

    // Apple's own mapping per controller, so every reload merges against it and never against an earlier merge
    private static let appleMappings = NSMapTable<NSObject, NSDictionary>.weakToStrongObjects()
    // Controller emulation mapping: Apple's key handler reads `_buttons` without retaining it, so no dictionary
    // that was ever applied may be freed by a reload.
    // ponytail: tiny memory per edit, bounded by user edits; never released
    private static var appliedMappings: [NSDictionary] = []
    // Guards appleMappings, appliedMappings, comboEngine and comboKeySender (the hooks may run off-main)
    private static let stateLock = NSLock()
    // Controller combos: nil when the applied file has no valid combo, so the key hook passes straight through.
    // ponytail: one global engine for every emulated controller (one keyboard); per-controller engines if
    // several keyboards ever drive separate emulated controllers
    private static var comboEngine: EmulatedControllerComboEngine?
    // Controller combos: calls Apple's original -updateWithKeyKey:down: (set once the key hook is installed)
    public typealias ComboKeySender = (NSObject, Int64, Bool) -> Void
    private static var comboKeySender: ComboKeySender?
    // Main queue only
    private static var directoryWatcher: DispatchSourceFileSystemObject?
    private static var pendingReload: DispatchWorkItem?

    private struct LiveApplyTarget {
        let controllerClass: AnyClass
        let mappingIvar: Ivar
    }

    // Controller combos: the file as both the merge and the combo engine read it
    private struct FileLayout {
        let buttons: [Int: Int]
        let combos: [EmulatedControllerComboEngine.Combo]
    }

    // Resolved on first reload, which only happens after the hook found the class loaded
    private static let liveApplyTarget = resolveLiveApplyTarget()

    // Controller emulation mapping: store an immutable copy so later mutation by the caller cannot leak in
    @objc(rememberAppleMapping:forController:)
    public static func rememberAppleMapping(_ mapping: NSDictionary, for controller: NSObject) {
        let snapshot = mapping.copy() as? NSDictionary ?? mapping
        stateLock.lock()
        defer { stateLock.unlock() }
        appleMappings.setObject(snapshot, forKey: controller)
    }

    // Controller emulation mapping: the result goes into Apple's `_mapping`, so it is kept alive forever
    @objc public static func mergedMapping(_ appleMapping: NSDictionary) -> NSDictionary {
        let merged = merge(apple: appleMapping, file: parseMappingFile(readMappingData()))
        keepAlive([merged])
        return merged
    }

    // Controller emulation mapping: called once by the ObjC installer right after the remap hook is in place
    @objc public static func hookDidInstall() {
        DispatchQueue.main.async {
            #if DEBUG
            selfCheck()
            #endif
            startWatchingDirectory()
            // Late install: controllers Apple remapped before the hook existed pick up the file now
            reloadControllers()
        }
    }

    // Controller combos: called by the ObjC installer right after the key hook is in place (before hookDidInstall,
    // so its first reload builds the engine); `sender` reaches Apple's original key handler without the hook
    @objc(comboHookDidInstallWithSender:)
    public static func comboHookDidInstall(sender: @escaping ComboKeySender) {
        stateLock.lock()
        defer { stateLock.unlock() }
        comboKeySender = sender
    }

    // Controller combos: called by the key hook; false = not a combo-engine key, so Apple handles it unchanged.
    // Events are sent outside the lock, since Apple's handler may call back into game code
    @objc(handleComboKey:down:controller:)
    public static func handleComboKey(_ key: Int64, isDown: Bool, controller: NSObject) -> Bool {
        guard let result = comboEvents(forKey: Int(key), isDown: isDown) else { return false }
        send(result.events, to: [controller], via: result.sender)
        return true
    }

    // Controller combos: one locked step so the engine state and its sender are read together
    private static func comboEvents(
        forKey key: Int, isDown: Bool
    ) -> (events: [EmulatedControllerComboEngine.KeyEvent], sender: ComboKeySender)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let sender = comboKeySender, comboEngine?.handles(key: key) == true,
              let events = comboEngine?.update(key: key, isDown: isDown) else {
            return nil
        }
        return (events, sender)
    }

    // Controller combos: deliver engine events through Apple's original key handler
    private static func send(_ events: [EmulatedControllerComboEngine.KeyEvent], to controllers: [NSObject],
                             via sender: ComboKeySender) {
        for controller in controllers {
            for event in events {
                sender(controller, Int64(event.usage), event.isDown)
            }
        }
    }

    // Controller emulation mapping: re-apply the file to every emulated controller (idempotent, main queue only);
    // also called on controller connect for controllers that show up after the hook was installed.
    // Swaps `_mapping` and rebuilds `_buttons` via -setupButtons; never calls -remapControlsWith: again,
    // which would start a second set of timers
    @objc public static func reloadControllers() {
        guard let target = liveApplyTarget else { return }
        let file = parseMappingFile(readMappingData())
        let controllers = GCController.controllers().filter { $0.isKind(of: target.controllerClass) }
        // Controller combos: swap the engine before the mappings, while the old synthetic entries still exist
        rebuildComboEngine(layout: fileLayout(file), releasingOn: controllers)
        for controller in controllers {
            guard let apple = appleMapping(of: controller, mappingIvar: target.mappingIvar) else { continue }
            let merged = merge(apple: apple, file: file)
            let previous = object_getIvar(controller, target.mappingIvar) as? NSDictionary
            if let previous, previous.isEqual(merged) { continue }
            keepAlive([previous, merged].compactMap { $0 })
            object_setIvarWithStrongDefault(controller, target.mappingIvar, merged)
            _ = controller.perform(setupButtonsSelector)
        }
    }

    // Controller combos: replace the engine only when the layout changed (reloads also fire for unrelated files and
    // controller connects); the old engine's pressed inputs are released first, so nothing stays stuck
    private static func rebuildComboEngine(layout: FileLayout?, releasingOn controllers: [NSObject]) {
        let combos = layout?.combos ?? []
        let next = combos.isEmpty ? nil
            : EmulatedControllerComboEngine(buttons: layout?.buttons ?? [:], combos: combos)
        stateLock.lock()
        guard comboEngine?.buttons != next?.buttons || comboEngine?.combos != next?.combos else {
            stateLock.unlock()
            return
        }
        let releaseEvents = comboEngine?.releaseAll() ?? []
        comboEngine = next
        let sender = comboKeySender
        stateLock.unlock()
        guard let sender else { return }
        send(releaseEvents, to: controllers, via: sender)
    }

    // Controller emulation mapping: pure merge; Apple's mapping passes through unless the file is enabled and valid.
    // Controller combos: with at least one combo, every input also gets its synthetic usage for the combo engine
    static func merge(apple: NSDictionary, file: NSDictionary?) -> NSDictionary {
        guard let layout = fileLayout(file),
              let merged = apple.mutableCopy() as? NSMutableDictionary else {
            return apple
        }
        let buttons = NSMutableDictionary()
        for (usage, inputIndex) in layout.buttons {
            buttons[NSNumber(value: usage)] = NSNumber(value: inputIndex)
        }
        if !layout.combos.isEmpty {
            for inputIndex in validInputIndices {
                let usage = EmulatedControllerComboEngine.syntheticUsage(for: inputIndex)
                buttons[NSNumber(value: usage)] = NSNumber(value: inputIndex)
            }
        }
        merged[buttonsKey] = buttons
        return merged
    }

    // Controller combos: the single reading of the file shared by merge and the combo engine; nil when Apple's
    // mapping stays (missing or disabled file, no Buttons, or a non-empty Buttons with no valid entry).
    // An empty Buttons is a valid layout, so a file with only combos still applies
    private static func fileLayout(_ file: NSDictionary?) -> FileLayout? {
        guard let file, (file[enabledKey] as? Bool) == true,
              let fileButtons = file[buttonsKey] as? NSDictionary,
              let buttons = numericButtons(from: fileButtons) else {
            return nil
        }
        return FileLayout(buttons: buttons, combos: parseCombos(file[combosKey]))
    }

    // Controller emulation mapping: plist keys arrive as strings, Apple looks buttons up by number;
    // nil when a non-empty layout has no valid entry (bad file)
    private static func numericButtons(from fileButtons: NSDictionary) -> [Int: Int]? {
        var buttons: [Int: Int] = [:]
        for (key, value) in fileButtons {
            guard let usage = integer(from: key), usage > 0,
                  let inputIndex = integer(from: value), validInputIndices.contains(inputIndex) else {
                continue
            }
            buttons[usage] = inputIndex
        }
        let droppedCount = fileButtons.count - buttons.count
        if droppedCount > 0 {
            print("[PlayTools] Dropped \(droppedCount) invalid controller emulation key mapping(s)")
        }
        let isBadLayout = buttons.isEmpty && fileButtons.count > 0
        return isBadLayout ? nil : buttons
    }

    // Controller combos: missing `Combos` means none; invalid entries are dropped and logged, the rest apply
    private static func parseCombos(_ object: Any?) -> [EmulatedControllerComboEngine.Combo] {
        guard let object else { return [] }
        guard let entries = object as? [Any] else {
            print("[PlayTools] Ignored controller combos: not an array")
            return []
        }
        let combos = entries.compactMap(parseCombo)
        let droppedCount = entries.count - combos.count
        if droppedCount > 0 {
            print("[PlayTools] Dropped \(droppedCount) invalid controller combo(s)")
        }
        return combos
    }

    // Controller combos: one {Keys, Inputs, Priority} entry; nil when either list is empty or holds an invalid
    // value. A missing or unknown Priority falls back to "Combo" (the behaviour before Priority existed)
    private static func parseCombo(_ entry: Any) -> EmulatedControllerComboEngine.Combo? {
        guard let entry = entry as? NSDictionary,
              let keys = integerSet(from: entry[comboKeysKey], isValid: { $0 > 0 }),
              let inputs = integerSet(from: entry[comboInputsKey], isValid: { validInputIndices.contains($0) }) else {
            return nil
        }
        let priority = (entry[comboPriorityKey] as? String).flatMap(EmulatedControllerComboEngine.Priority.init)
        return EmulatedControllerComboEngine.Combo(keys: keys, inputs: inputs, priority: priority ?? .combo)
    }

    // Controller combos: a non-empty array whose every element is a valid integer; duplicates collapse
    private static func integerSet(from object: Any?, isValid: (Int) -> Bool) -> Set<Int>? {
        guard let array = object as? [Any], !array.isEmpty else { return nil }
        var values = Set<Int>()
        for element in array {
            guard let value = integer(from: element), isValid(value) else { return nil }
            values.insert(value)
        }
        return values
    }

    // Controller emulation mapping: plist keys arrive as strings ("44"), values as numbers; accept either
    private static func integer(from object: Any) -> Int? {
        if let string = object as? String {
            return Int(string)
        }
        return object as? Int
    }

    // Controller emulation mapping: missing file is the normal "feature off" case and stays silent
    private static func readMappingData() -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            print("[PlayTools] Failed to read controller emulation mapping: \(error)")
            return nil
        }
    }

    // Controller emulation mapping: a malformed plist is logged and treated as "no file"
    private static func parseMappingFile(_ data: Data?) -> NSDictionary? {
        guard let data else { return nil }
        do {
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        } catch {
            print("[PlayTools] Failed to parse controller emulation mapping: \(error)")
            return nil
        }
    }

    // Controller emulation mapping: retain applied dictionaries for the process lifetime (see appliedMappings)
    private static func keepAlive(_ mappings: [NSDictionary]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        appliedMappings.append(contentsOf: mappings)
    }

    // Controller emulation mapping: watch the directory, since PlayCover's atomic writes replace the file;
    // if the directory itself is deleted or renamed, recreate it and re-arm the watcher
    private static func startWatchingDirectory() {
        guard directoryWatcher == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            print("[PlayTools] Failed to create EmulatedController directory: \(error)")
            return
        }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            print("[PlayTools] Failed to watch EmulatedController directory (errno \(errno))")
            return
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        watcher.setEventHandler {
            if !watcher.data.isDisjoint(with: [.delete, .rename]) {
                watcher.cancel()
                directoryWatcher = nil
                startWatchingDirectory()
            }
            scheduleReload()
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        directoryWatcher = watcher
    }

    // Controller emulation mapping: collapse the burst of directory events from one save into a single reload;
    // other apps' plists also trigger it, but the per-controller isEqual skip makes that a no-op
    private static func scheduleReload() {
        pendingReload?.cancel()
        let reload = DispatchWorkItem { reloadControllers() }
        pendingReload = reload
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadDebounce, execute: reload)
    }

    // Controller emulation mapping: a controller remapped before the hook existed still holds Apple's mapping
    private static func appleMapping(of controller: GCController, mappingIvar: Ivar) -> NSDictionary? {
        stateLock.lock()
        let remembered = appleMappings.object(forKey: controller)
        stateLock.unlock()
        if let remembered {
            return remembered
        }
        guard let current = object_getIvar(controller, mappingIvar) as? NSDictionary else { return nil }
        rememberAppleMapping(current, for: controller)
        return current
    }

    // Controller emulation mapping: check the private layout once; on mismatch log and keep Apple's behaviour
    private static func resolveLiveApplyTarget() -> LiveApplyTarget? {
        guard let controllerClass = NSClassFromString(emulatedControllerClassName),
              let mappingIvar = class_getInstanceVariable(controllerClass, mappingIvarName),
              let encoding = ivar_getTypeEncoding(mappingIvar),
              String(cString: encoding).hasPrefix(objectTypeEncodingPrefix),
              class_respondsToSelector(controllerClass, setupButtonsSelector) else {
            print("[PlayTools] Controller emulation live reload unavailable: unexpected class layout")
            return nil
        }
        return LiveApplyTarget(controllerClass: controllerClass, mappingIvar: mappingIvar)
    }

    #if DEBUG
    // Controller emulation mapping: assert-based check of the pure merge, run once at start-up in DEBUG builds
    static func selfCheck() {
        let appleButtons: NSDictionary = [NSNumber(value: 44): NSNumber(value: 4)]
        let appleConfig: NSDictionary = ["MouseSensitivity": NSNumber(value: 1)]
        let apple: NSDictionary = [buttonsKey: appleButtons, "Config": appleConfig]
        let fileButtons: NSDictionary = ["29": 20, "6": NSNumber(value: 24), "x": 1, "0": 3, "27": 25]

        assert(merge(apple: apple, file: nil) === apple, "Missing file must pass Apple's mapping through")
        let disabled: NSDictionary = [enabledKey: false, buttonsKey: fileButtons]
        assert(merge(apple: apple, file: disabled) === apple, "Enabled=false must pass Apple's mapping through")
        let allInvalid: NSDictionary = [enabledKey: true, buttonsKey: ["x": 1]]
        assert(merge(apple: apple, file: allInvalid) === apple, "A layout with no valid entry must be ignored")

        let enabled: NSDictionary = [enabledKey: true, buttonsKey: fileButtons]
        let merged = merge(apple: apple, file: enabled)
        let expectedButtons: NSDictionary = [
            NSNumber(value: 29): NSNumber(value: 20),
            NSNumber(value: 6): NSNumber(value: 24)
        ]
        assert((merged[buttonsKey] as? NSDictionary) == expectedButtons, "Buttons must be NSNumber, invalid dropped")
        assert((merged["Config"] as? NSDictionary) == appleConfig, "Config must be kept from Apple's mapping")
        assert(fileLayout(enabled)?.combos.isEmpty == true, "No Combos must mean no combo engine")

        comboSelfCheck(apple: apple)
        EmulatedControllerComboEngine.selfCheck()
    }

    // Controller combos: assert-based check of combo parsing and the synthetic Buttons entries
    private static func comboSelfCheck(apple: NSDictionary) {
        let rCombo: NSDictionary = [comboKeysKey: [21], comboInputsKey: [8, 9, 6, 6]]
        let chordCombo: NSDictionary = [comboKeysKey: ["225", 26, 26] as [Any], comboInputsKey: [4]]
        let invalidCombos: [NSDictionary] = [
            [comboKeysKey: [Int](), comboInputsKey: [4]],
            [comboKeysKey: [0], comboInputsKey: [4]],
            [comboKeysKey: ["x"], comboInputsKey: [4]],
            [comboKeysKey: [5], comboInputsKey: [25]],
            [comboKeysKey: [5]]
        ]
        let entries: [Any] = [rCombo] + (invalidCombos as [Any]) + ["not a combo", chordCombo]
        let parsed = parseCombos(entries)
        let expected = [
            EmulatedControllerComboEngine.Combo(keys: [21], inputs: [6, 8, 9]),
            EmulatedControllerComboEngine.Combo(keys: [225, 26], inputs: [4])
        ]
        assert(parsed == expected, "Valid combos must be kept in file order, deduped, invalid ones dropped")
        assert(parseCombos(nil).isEmpty && parseCombos("x").isEmpty, "Missing or malformed Combos must mean none")
        let priorities = ["Keys", "Both", "bogus"].map { name -> NSDictionary in
            [comboKeysKey: [21], comboInputsKey: [4], comboPriorityKey: name]
        }
        assert(parseCombos(priorities).map(\.priority) == [.keys, .both, .combo],
               "Priority must parse, an unknown one falling back to Combo like a missing one")

        let syntheticEntryCount = validInputIndices.count
        let withCombos: NSDictionary = [enabledKey: true, buttonsKey: ["26": 10], combosKey: [rCombo]]
        let mergedButtons = merge(apple: apple, file: withCombos)[buttonsKey] as? NSDictionary
        assert(mergedButtons?.count == 1 + syntheticEntryCount, "Combos must add one synthetic entry per input")
        let syntheticL1 = NSNumber(value: EmulatedControllerComboEngine.syntheticUsage(for: 8))
        assert(mergedButtons?[syntheticL1] as? NSNumber == NSNumber(value: 8), "Synthetic usage must map to its input")
        assert(mergedButtons?[NSNumber(value: 26)] as? NSNumber == NSNumber(value: 10), "Real keys must be kept")

        let combosOnly: NSDictionary = [enabledKey: true, buttonsKey: NSDictionary(), combosKey: [rCombo]]
        let combosOnlyButtons = merge(apple: apple, file: combosOnly)[buttonsKey] as? NSDictionary
        assert(combosOnlyButtons?.count == syntheticEntryCount, "Empty Buttons with combos must still apply")
        let disabled: NSDictionary = [enabledKey: false, buttonsKey: ["26": 10], combosKey: [rCombo]]
        assert(merge(apple: apple, file: disabled) === apple && fileLayout(disabled) == nil,
               "Combos must not apply while the layout is disabled")
    }
    #endif
}
