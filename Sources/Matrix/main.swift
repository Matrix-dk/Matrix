import AppKit

// 没有用 SwiftUI App 生命周期，因为菜单栏常驻小程序用 NSStatusItem + NSPopover 更可控。
// 整个 app 是 accessory（LSUIElement=true），不出现在 Dock 与 Cmd+Tab。
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
