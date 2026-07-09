import AppKit

let app = NSApplication.shared
// A regular app: Dock icon + Cmd-Tab presence while running, like any other
// app. Opening Talkeo shows the main window AND activates the ambient feature
// (floating bar + menu bar item), which keeps running when the window closes.
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
