import Foundation

/// Python 版本門檻探測(2026-10-05 上線前盤查)。
///
/// bridge.py 用了 127 處 PEP 604 型別語法(`X | None`),**需要 ≥3.10**;
/// 而 macOS CLT 的 /usr/bin/python3 是 3.9 —— 用它建 venv,import 當下就
/// SyntaxError,使用者只看到「bridge 起不來」。沒裝 Homebrew 的乾淨 Mac
/// 百分之百踩中。候選挑選一律先過這關,寧可回報缺 Python 教使用者裝新版,
/// 也不要選一顆必死的進去。
public enum PythonProbe {

    /// `python -c` 問版本,≥minimum 才放行。跑不動/輸出怪 → 一律不合格。
    public static func meetsMinimum(_ path: String,
                                    minimum: (major: Int, minor: Int) = (3, 10)) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-c", "import sys; print(sys.version_info[0], sys.version_info[1])"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) else { return false }
        let nums = text.split(separator: " ")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard nums.count >= 2 else { return false }
        return (nums[0], nums[1]) >= (minimum.major, minimum.minor)
    }
}
