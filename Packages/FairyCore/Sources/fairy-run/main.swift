import Foundation

// fairy-run 入口：见 CLI.swift。
let code = await CLI.main(Array(CommandLine.arguments.dropFirst()))
exit(code)
