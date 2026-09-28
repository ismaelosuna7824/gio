import CoreGraphics
import Foundation

func pocFail(_ message: String, code: Int32 = 1) -> Never {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}

func pocPermissionMessage() -> String {
    "Accessibility permission missing: enable gio-poc under System Settings → Privacy & Security → Accessibility, then retry."
}

let pocArguments = Array(CommandLine.arguments.dropFirst())
let pocCommand: POCCommand = {
    switch parsePOCCommand(pocArguments) {
    case .success(let command):
        return command
    case .failure:
        pocFail(pocUsage(), code: 2)
    }
}()

func pocEnumerate() -> POCDiscoveryResult {
    do {
        return try pocDiscoverWindows()
    } catch is POCPermissionError {
        pocFail(pocPermissionMessage())
    } catch {
        pocFail("discovery failed: \(error)")
    }
}

switch pocCommand {
case .help:
    print(pocUsage())
case .listWindows:
    let result = pocEnumerate()
    print("windows=\(result.windows.count) skipped=\(result.skipped)")
    for found in result.windows {
        print(found.window.describe())
    }
case .focus(let index):
    let result = pocEnumerate()
    do {
        let target = try pocWindow(at: index, in: result.windows)
        try pocFocus(target)
        print("focused: \(target.window.describe())")
    } catch let error as POCActionError {
        pocFail("focus failed: \(error.description)")
    } catch {
        pocFail("focus failed: \(error)")
    }
case .move(let index, let x, let y):
    let result = pocEnumerate()
    do {
        let target = try pocWindow(at: index, in: result.windows)
        let actual = try pocMove(target, to: CGPoint(x: x, y: y))
        print("moved: \(target.window.describe()) actual=\(describeFrame(actual))")
    } catch let error as POCActionError {
        pocFail("move failed: \(error.description)")
    } catch {
        pocFail("move failed: \(error)")
    }
case .resize(let index, let width, let height):
    let result = pocEnumerate()
    do {
        let target = try pocWindow(at: index, in: result.windows)
        let actual = try pocResize(target, to: CGSize(width: width, height: height))
        print("resized: \(target.window.describe()) actual=\(describeFrame(actual))")
    } catch let error as POCActionError {
        pocFail("resize failed: \(error.description)")
    } catch {
        pocFail("resize failed: \(error)")
    }
case .events:
    do {
        try pocRequirePermission()
    } catch {
        pocFail(pocPermissionMessage())
    }
    pocListenForEvents()
}
