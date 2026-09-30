import Foundation
import Testing
import RuntimeContracts
@testable import SwiftRuntime

@Suite("Audit: runtime boundaries", .timeLimit(.minutes(1)))
struct AuditRuntimeRegressionTests {
    @Test func rangePredicateReturnsElementIndex() async throws {
        let result = try await runScript("print((10..<15).firstIndex(where: { $0 == 12 }) ?? -1)")
        #expect(result.errors.isEmpty)
        #expect(result.console == "12\n")
    }

    @Test func collectionGrowthRejectedBeforeMaterializingRange() async throws {
        let result = try await runScript("var a = [0]\na.append(contentsOf: 0..<1000000)",
            budget: TestSupport.budget(maxElements: 16))
        #expect(result.isBudget)
    }

    @Test func hugeFormatPrecisionIsBudgetError() async throws {
        let result = try await runScript("print(String(format: \"%.999999999f\", 1.0))")
        #expect(result.isBudget)
    }

    @Test func unrepresentableMagnitudeIsNotNegative() async throws {
        let result = try await runScript("print(Int.min.magnitude)")
        #expect(!result.console.contains("-9223372036854775808"))
        #expect(result.diagnostics.contains { $0.kind == .unsupportedAPI })
    }
}
