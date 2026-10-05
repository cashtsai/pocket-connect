import XCTest
@testable import PocketConnectKit

/// Python 版本門檻(2026-10-05):CLT 3.9 必須被擋、3.10+ 放行、壞執行檔不炸。
/// 用假直譯器(shell script 印固定版本)測,不依賴機器上裝了什麼。
final class PythonProbeTests: XCTestCase {

    private func fakePython(printing version: String) throws -> String {
        let dir = NSTemporaryDirectory() + "pyprobe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/python3"
        // 假直譯器忽略引數,固定印「major minor」—— 與真 python -c 的輸出同形。
        try "#!/bin/sh\necho \(version)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testOldCLTPythonIsRejected() throws {
        XCTAssertFalse(PythonProbe.meetsMinimum(try fakePython(printing: "3 9")),
                       "3.9(CLT)必須被擋 —— 放進去就是 import SyntaxError")
    }

    func testMinimumAndNewerPass() throws {
        XCTAssertTrue(PythonProbe.meetsMinimum(try fakePython(printing: "3 10")))
        XCTAssertTrue(PythonProbe.meetsMinimum(try fakePython(printing: "3 14")))
        XCTAssertTrue(PythonProbe.meetsMinimum(try fakePython(printing: "4 0")))
    }

    func testGarbageAndMissingAreRejectedWithoutCrash() throws {
        XCTAssertFalse(PythonProbe.meetsMinimum(try fakePython(printing: "banana")))
        XCTAssertFalse(PythonProbe.meetsMinimum("/no/such/python3"))
    }

    func testCustomMinimum() throws {
        XCTAssertTrue(PythonProbe.meetsMinimum(try fakePython(printing: "3 9"),
                                               minimum: (3, 9)))
    }
}
