import Foundation

/// Canonical location of the user's config.
public func gioConfigPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/config.toml"
}

/// Patch the config file at `path` (created from `defaultConfigTemplate()`
/// when missing). The new text is written only after it parses cleanly,
/// through a temp file in the same directory and an atomic rename, so a
/// crash or a rejected edit never leaves a half-written or invalid file.
public func applyConfigEdits(
    _ edits: [ConfigEdit], toFileAt path: String = gioConfigPath()
) -> Result<PatchedConfig, ConfigErrors> {
    let current: String
    if FileManager.default.fileExists(atPath: path) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure(ConfigErrors(messages: ["cannot read \(path)"]))
        }
        current = text
    } else {
        current = defaultConfigTemplate()
    }
    let patched: PatchedConfig
    switch patchGioConfig(current, edits: edits) {
    case .success(let value): patched = value
    case .failure(let errors): return .failure(errors)
    }
    do {
        try writeAtomically(patched.text, to: path)
    } catch {
        return .failure(ConfigErrors(messages: ["cannot write \(path): \(error.localizedDescription)"]))
    }
    return .success(patched)
}

private func writeAtomically(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    do {
        try text.write(to: temp, atomically: false, encoding: .utf8)
        guard rename(temp.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}
