import AppKit
import ApplicationServices

/// Thin, type-checked wrappers over the C Accessibility API.
/// Every accessor checks the CF type before casting, since `as?` on
/// non-bridged CF types is not reliable.
extension AXUIElement {
    private func rawAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    func bool(_ name: String) -> Bool? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    func element(_ name: String) -> AXUIElement? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! [AnyObject]
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    func point(_ name: String) -> CGPoint? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var result = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &result) else { return nil }
        return result
    }

    func size(_ name: String) -> CGSize? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var result = CGSize.zero
        guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &result) else { return nil }
        return result
    }

    /// Window frame in top-left-origin screen coordinates, the same space
    /// `CGWindowListCopyWindowInfo` reports `kCGWindowBounds` in.
    var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    @discardableResult
    func set(_ name: String, to value: Bool) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Stable identifier for the underlying window token. `CFHash` on an
    /// AXUIElement hashes the token, not the wrapper object, so two copies
    /// referring to the same window hash the same.
    var stableHash: UInt { CFHash(self) }
}
