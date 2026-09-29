import AppKit
import CoreGraphics
import Foundation
import GioMacOS

func cliFail(_ message: String, code: Int32 = 1) -> Never {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}

func cliPermissionMessage() -> String {
    "Accessibility permission missing: enable gio-poc under System Settings → Privacy & Security → Accessibility, then retry."
}

/// Shows the system accessibility dialog first (CLI tools never get it
/// otherwise), then exits with guidance.
func cliPermissionDenied() -> Never {
    _ = requestAXPermission()
    cliFail(cliPermissionMessage())
}

let cliArguments = Array(CommandLine.arguments.dropFirst())
let cliCommand: CLICommand = {
    switch parseCLICommand(cliArguments) {
    case .success(let command):
        return command
    case .failure:
        cliFail(cliUsage(), code: 2)
    }
}()

func cliEnumerate() -> SystemWindowDiscoveryResult {
    do {
        return try discoverSystemWindows()
    } catch is AXPermissionError {
        cliPermissionDenied()
    } catch {
        cliFail("discovery failed: \(error)")
    }
}

switch cliCommand {
case .help:
    print(cliUsage())
case .listWindows:
    let result = cliEnumerate()
    print("windows=\(result.windows.count) skipped=\(result.skipped)")
    for found in result.windows {
        print(found.window.describe())
    }
case .focus(let index):
    let result = cliEnumerate()
    do {
        let target = try systemWindow(at: index, in: result.windows)
        try focusSystemWindow(target)
        print("focused: \(target.window.describe())")
    } catch let error as SystemWindowActionError {
        cliFail("focus failed: \(error.description)")
    } catch {
        cliFail("focus failed: \(error)")
    }
case .move(let index, let x, let y):
    let result = cliEnumerate()
    do {
        let target = try systemWindow(at: index, in: result.windows)
        let actual = try moveSystemWindow(target, to: CGPoint(x: x, y: y))
        print("moved: \(target.window.describe()) actual=\(describeFrame(actual))")
    } catch let error as SystemWindowActionError {
        cliFail("move failed: \(error.description)")
    } catch {
        cliFail("move failed: \(error)")
    }
case .resize(let index, let width, let height):
    let result = cliEnumerate()
    do {
        let target = try systemWindow(at: index, in: result.windows)
        let actual = try resizeSystemWindow(target, to: CGSize(width: width, height: height))
        print("resized: \(target.window.describe()) actual=\(describeFrame(actual))")
    } catch let error as SystemWindowActionError {
        cliFail("resize failed: \(error.description)")
    } catch {
        cliFail("resize failed: \(error)")
    }
case .events:
    do {
        try requireAXPermission()
    } catch {
        cliPermissionDenied()
    }
    listenForSystemWindowEvents()
case .restore:
    do {
        let report = try runRestoreOffscreen()
        print(report.describe())
    } catch is AXPermissionError {
        cliPermissionDenied()
    } catch {
        cliFail("restore failed: \(error)")
    }
case .tile:
    guard let screen = NSScreen.main,
          screen.visibleFrame.width > 0, screen.visibleFrame.height > 0
    else {
        cliFail("tile failed: no usable main display")
    }
    do {
        let report = try runTileReflow(
            display: screen.visibleFrame, displayHeight: screen.frame.height
        )
        print(report.describe())
    } catch is AXPermissionError {
        cliPermissionDenied()
    } catch {
        cliFail("tile failed: \(error)")
    }
}
