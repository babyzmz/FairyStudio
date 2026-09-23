import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

/// 差分测试：每个夹具用本机 swiftc 编译运行得到期望 stdout，与解释器的 console 输出逐字节比较。
///
/// - 本机程序链接一个把 stdout 设为无缓冲的 C 构造函数，使 trap 之前的输出不会因进程崩溃而丢失。
/// - 编译结果按（源码 + 编译器版本）哈希缓存在临时目录，避免每次重复编译。
enum NativeSwift {
    struct Result: Codable { var stdout: String; var exitCode: Int32 }

    static func run(_ command: String, _ args: [String], cwd: URL? = nil, stdout: URL? = nil) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    static let compilerVersion: String = {
        (try? run("/usr/bin/xcrun", ["swiftc", "--version"])).map { String(decoding: $0.1, as: UTF8.self) } ?? "unknown"
    }()

    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func expected(for source: URL) throws -> Result {
        let code = try String(contentsOf: source, encoding: .utf8)
        let key = fnv1a(code + compilerVersion + "v2")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fairy-differential/\(key)")
        let cache = dir.appendingPathComponent("result.json")
        if let data = try? Data(contentsOf: cache), let r = try? JSONDecoder().decode(Result.self, from: data) { return r }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("unbuf.c")
        try "#include <stdio.h>\n__attribute__((constructor)) static void fairy_unbuffer(void) { setvbuf(stdout, NULL, _IONBF, 0); }\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        let (cs, _) = try run("/usr/bin/xcrun", ["clang", "-c", shim.path, "-o", dir.appendingPathComponent("unbuf.o").path])
        guard cs == 0 else { throw NSError(domain: "clang", code: Int(cs)) }
        let bin = dir.appendingPathComponent("prog")
        let (ss, _) = try run("/usr/bin/xcrun", ["swiftc", "-module-name", "main", "-Onone", source.path,
                                                 dir.appendingPathComponent("unbuf.o").path, "-o", bin.path])
        guard ss == 0 else { throw NSError(domain: "swiftc 编译夹具失败：\(source.lastPathComponent)", code: Int(ss)) }
        let (status, out) = try run(bin.path, [], cwd: dir)
        let r = Result(stdout: String(decoding: out, as: UTF8.self), exitCode: status)
        try JSONEncoder().encode(r).write(to: cache)
        return r
    }
}

@Suite("差分测试（本机 swiftc 对照）", .timeLimit(.minutes(5)))
struct DifferentialTests {
    static let fixtureNames: [String] = {
        let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("differential")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
    }()

    @Test func atLeast25Fixtures() {
        #expect(Self.fixtureNames.count >= 25)
    }

    @Test(arguments: fixtureNames)
    func differential(fixture: String) async throws {
        let url = TestSupport.fixturesURL.appendingPathComponent("differential/\(fixture)")
        let expected = try NativeSwift.expected(for: url)
        let code = try String(contentsOf: url, encoding: .utf8)
        let out = try await runScript(TestSupport.program(TestSupport.files([(fixture, code)])))
        #expect(out.errors.filter { $0.kind != .runtimeTrap }.isEmpty, "\(out.errors.map(\.message))")
        #expect(out.console == expected.stdout, "stdout 不一致：\n--- swiftc ---\n\(expected.stdout)\n--- fairy ---\n\(out.console)")
        if expected.exitCode == 0 {
            #expect(out.finished == .completed)
        } else {
            #expect(out.isTrap, "本机退出码 \(expected.exitCode)，解释器结束原因 \(String(describing: out.finished))")
            #expect(out.errors.contains { $0.kind == .runtimeTrap })
        }
    }
}
