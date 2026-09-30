import Foundation
import RuntimeContracts
import Testing
@testable import SwiftRuntime

/// W4 标准库扩容：字典序列方法（插入顺序语义，Swift 原生无序 → 不做差分）与
/// zip / repeatElement 结构、rounded 规则、fatalError 受控 trap。
@Suite("W4 标准库：字典序列 / zip / repeatElement", .timeLimit(.minutes(2)))
struct W4StdlibTests {
    func runConsole(_ code: String) async throws -> String {
        let outcome = try await runScript(TestSupport.script(code))
        #expect(outcome.errors.isEmpty, "诊断：\(outcome.errors.map(\.message))")
        return outcome.console
    }

    // MARK: - 字典序列方法

    @Test func dictionarySequenceOps() async throws {
        // map / keys：插入顺序。
        let map = try await runConsole("""
        let ages = ["b": 2, "a": 1]
        print(ages.map { $0.0 })
        print(ages.keys)
        """)
        #expect(map == "[\"b\", \"a\"]\n[\"b\", \"a\"]\n")
        // mapValues / filter：保留插入顺序。
        let derived = try await runConsole("""
        let prices = ["b": 2, "a": 1]
        let doubled = prices.mapValues { $0 * 10 }
        print(doubled["b"] ?? -1, doubled["a"] ?? -1)
        let expensive = prices.filter { $0.value > 1 }
        print(expensive.count, expensive["b"] ?? 0)
        """)
        #expect(derived == "20 10\n1 2\n")
        // updateValue 返回旧值；removeAll。
        let update = try await runConsole("""
        var stock = ["x": 1]
        let old = stock.updateValue(5, forKey: "x")
        print(old ?? -1, stock["x"] ?? -1)
        stock.removeAll()
        print(stock.count, stock.isEmpty)
        """)
        #expect(update == "1 5\n0 true\n")
        // contains(where:) / allSatisfy / reduce：元素为 (key:, value:) 元组。
        let predicates = try await runConsole("""
        let scores = ["m": 3, "n": 7]
        print(scores.contains { $0.value > 5 }, scores.allSatisfy { $0.value > 0 })
        let total = scores.reduce(0) { acc, pair in acc + pair.value }
        print(total)
        """)
        #expect(predicates == "true true\n10\n")
        // min(by:) / max(by:) / compactMap / first(where:)。
        let extremes = try await runConsole("""
        let items = ["p": 5, "q": 2]
        print(items.min { $0.0 < $1.0 }?.key ?? "-", items.max { $0.0 < $1.0 }?.key ?? "-")
        print(items.compactMap { $0.value > 3 ? $0.key : nil })
        print(items.first { $0.value == 2 }?.key ?? "-")
        """)
        #expect(extremes == "p q\n[\"p\"]\nq\n")
    }

    // MARK: - zip / repeatElement

    @Test func zipPairsShorterSide() async throws {
        let out = try try await runConsole("""
        let names = ["a", "b", "c"]
        let codes = [1, 2]
        for p in zip(names, codes) {
            print(p.0, p.1)
        }
        let pairs = Array(zip(codes, names))
        print(pairs.count, pairs[1].0, pairs[1].1)
        """)
        #expect(out == "a 1\nb 2\n2 2 b\n")
    }

    @Test func repeatElementMaterializes() async throws {
        let out = try try await runConsole("""
        let cells = Array(repeatElement(0, count: 3))
        print(cells, cells.count)
        let flags = repeatElement(true, count: 2)
        var hit = 0
        for f in flags {
            if f { hit += 1 }
        }
        print(hit)
        """)
        #expect(out == "[0, 0, 0] 3\n2\n")
    }

    // MARK: - Double 舍入规则 / 探测属性

    @Test func doubleRoundedRulesAndProbes() async throws {
        let out = try try await runConsole("""
        print(2.5.rounded(.up), 2.5.rounded(.down), 2.5.rounded(.toNearestOrEven))
        print((-2.5).rounded(.toNearestOrAwayFromZero))
        print(1.0.isNaN, Double.infinity.isInfinite, 1.0.isFinite)
        """)
        #expect(out == "3.0 2.0 2.0\n-3.0\nfalse true true\n")
    }

    // MARK: - 受控 trap

    @Test func fatalErrorIsControlledTrap() async throws {
        let outcome = try await runScript(TestSupport.script("print(\"前\")\nfatalError(\"炸\")\nprint(\"后\")"))
        #expect(outcome.isTrap)
        #expect(outcome.console == "前\n")
        #expect(outcome.diagnostics.contains { $0.message.contains("炸") })
    }
}
