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
}
