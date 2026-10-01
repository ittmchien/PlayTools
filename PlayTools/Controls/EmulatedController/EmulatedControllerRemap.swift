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
    // Guards appleMappings and appliedMappings (the hook may run off-main)
    private static let stateLock = NSLock()
    // Main queue only
    private static var directoryWatcher: DispatchSourceFileSystemObject?
    private static var pendingReload: DispatchWorkItem?

    private struct LiveApplyTarget {
        let controllerClass: AnyClass
        let mappingIvar: Ivar
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

    // Controller emulation mapping: re-apply the file to every emulated controller (idempotent, main queue only);
    // also called on controller connect for controllers that show up after the hook was installed.
    // Swaps `_mapping` and rebuilds `_buttons` via -setupButtons; never calls -remapControlsWith: again,
    // which would start a second set of timers
    @objc public static func reloadControllers() {
        guard let target = liveApplyTarget else { return }
        let file = parseMappingFile(readMappingData())
        for controller in GCController.controllers() where controller.isKind(of: target.controllerClass) {
            guard let apple = appleMapping(of: controller, mappingIvar: target.mappingIvar) else { continue }
            let merged = merge(apple: apple, file: file)
            let previous = object_getIvar(controller, target.mappingIvar) as? NSDictionary
            if let previous, previous.isEqual(merged) { continue }
            keepAlive([previous, merged].compactMap { $0 })
            object_setIvarWithStrongDefault(controller, target.mappingIvar, merged)
            _ = controller.perform(setupButtonsSelector)
        }
    }

    // Controller emulation mapping: pure merge; Apple's mapping passes through unless the file is enabled and valid
    static func merge(apple: NSDictionary, file: NSDictionary?) -> NSDictionary {
        guard let file, (file[enabledKey] as? Bool) == true,
              let fileButtons = file[buttonsKey] as? NSDictionary,
              let buttons = numericButtons(from: fileButtons),
              let merged = apple.mutableCopy() as? NSMutableDictionary else {
            return apple
        }
        merged[buttonsKey] = buttons
        return merged
    }

    // Controller emulation mapping: Apple looks buttons up by NSNumber, so plist string keys become NSNumber;
    // nil when a non-empty layout has no valid entry (bad file)
    private static func numericButtons(from fileButtons: NSDictionary) -> NSDictionary? {
        let buttons = NSMutableDictionary()
        for (key, value) in fileButtons {
            guard let usage = integer(from: key), usage > 0,
                  let inputIndex = integer(from: value), validInputIndices.contains(inputIndex) else {
                continue
            }
            buttons[NSNumber(value: usage)] = NSNumber(value: inputIndex)
        }
        let droppedCount = fileButtons.count - buttons.count
        if droppedCount > 0 {
            print("[PlayTools] Dropped \(droppedCount) invalid controller emulation key mapping(s)")
        }
        let isBadLayout = buttons.count == 0 && fileButtons.count > 0
        return isBadLayout ? nil : buttons
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
    }
    #endif
}
