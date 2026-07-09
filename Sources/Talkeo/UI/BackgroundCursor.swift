import AppKit

/// Grants this app the ability to change the cursor while it is NOT the
/// active app.
///
/// The floating bar and popovers are non-activating panels: the app behind
/// keeps focus while the user mouses over them. The window server only honors
/// cursor changes from the active app, so `NSCursor.set()` from our panels
/// can be silently ignored and whatever cursor the app behind asserts (a
/// focused terminal's I-beam, say) shows through. There is no supported API
/// to opt out; the established fix — used by Ice, Loop, Mac Mouse Fix,
/// Deskflow and others — is the window server's private
/// `SetsCursorInBackground` connection property.
///
/// Symbols are resolved with `dlsym` so a macOS release that drops them
/// degrades to a no-op (cursor sets go back to best-effort) instead of
/// failing at launch. Private API: fine for direct distribution, would not
/// pass App Store review.
enum BackgroundCursor {
    /// True once the window server accepted the property. Evaluated on first
    /// use, once per launch.
    static let isEnabled: Bool = {
        typealias MainConnectionFn = @convention(c) () -> CInt
        typealias SetPropertyFn = @convention(c) (CInt, CInt, CFString, CFTypeRef) -> CGError
        guard
            let handle = dlopen(nil, RTLD_LAZY),
            let mainSym = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
            let setSym = dlsym(handle, "CGSSetConnectionProperty")
        else { return false }
        let connection = unsafeBitCast(mainSym, to: MainConnectionFn.self)()
        let setProperty = unsafeBitCast(setSym, to: SetPropertyFn.self)
        return setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == .success
    }()

    /// Additionally tags one specific window with the window server's
    /// per-window "sets cursor in background" bit. The connection property
    /// above only lets our sets *compete*: the active app keeps re-asserting
    /// its own cursor whenever it redraws (a busy terminal does so even with
    /// the mouse still), and each exchange it wins shows as a brief cursor
    /// flicker. The window tag is how Spotlight-style panels solve this —
    /// it anchors cursor authority to the window under the cursor, so the
    /// active app's writes stop landing while the cursor is over ours.
    ///
    /// Gated to macOS 26: the bit position (5) is documented against that
    /// SkyLight's own tag table (via Loop's `SLSWindowTags`); on older
    /// systems we skip it rather than risk setting an unrelated tag, keeping
    /// the property-based behavior.
    ///
    /// The window must be on screen (have a window number); returns false to
    /// let the caller retry after the next order-front.
    @discardableResult
    static func tagWindow(_ window: NSWindow) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return false }
        typealias MainConnectionFn = @convention(c) () -> CInt
        typealias SetTagsFn = @convention(c) (CInt, UInt32, UnsafePointer<UInt64>, CInt) -> CGError
        guard
            let handle = dlopen(nil, RTLD_LAZY),
            let mainSym = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "CGSMainConnectionID"),
            let setSym = dlsym(handle, "SLSSetWindowTags") ?? dlsym(handle, "CGSSetWindowTags")
        else { return false }
        let connection = unsafeBitCast(mainSym, to: MainConnectionFn.self)()
        let setTags = unsafeBitCast(setSym, to: SetTagsFn.self)
        var tags: UInt64 = 1 << 5 // setsCursorInBackground
        return setTags(connection, UInt32(windowNumber), &tags, 64) == .success
    }
}
