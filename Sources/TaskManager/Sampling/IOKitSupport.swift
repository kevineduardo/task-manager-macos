import Foundation
import IOKit

/// Thin helpers over the IOKit registry C API.
enum IOReg {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    /// Calls `body` for every service matching `className`. Objects are released after the call.
    static func forEachService(matching className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func forEachChild(of entry: io_registry_entry_t, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
    }

    static func parent(of entry: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
        return parent
    }

    /// Walks up the service plane looking for a property, e.g. a PCI device's `model`.
    static func searchParents(_ entry: io_registry_entry_t, key: String, maxDepth: Int = 4) -> Any? {
        var current = entry
        var owned = false
        defer { if owned { IOObjectRelease(current) } }
        for _ in 0..<maxDepth {
            guard let next = parent(of: current) else { return nil }
            if owned { IOObjectRelease(current) }
            current = next
            owned = true
            if let value = property(current, key) { return value }
        }
        return nil
    }

    static func string(from value: Any?) -> String? {
        switch value {
        case let s as String:
            return s
        case let d as Data:
            let trimmed = d.prefix { $0 != 0 }
            return String(data: trimmed, encoding: .utf8)
        default:
            return nil
        }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }
}
