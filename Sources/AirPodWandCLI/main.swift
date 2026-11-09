//
//  main.swift
//  AirPodWandCLI
//
//  Command-line entry point and driver daemon (Requirement R4, Features 19, 20).
//

import Foundation
import AirPodWandCore

/// Operational modes supported by the AirPodWand CLI daemon.
public enum CLIMode: Sendable, Equatable {
    case simulateE2E
    case live
    case help
    case invalid(String)
}

/// Command-line argument parser for AirPodWandCLI.
public struct CLIArgsParser: Sendable {
    public static func parse(_ args: [String]) -> CLIMode {
        let cleanArgs = Array(args.dropFirst())
        if cleanArgs.isEmpty {
            // Default action: run synthetic closed-loop verification session
            return .simulateE2E
        }
        if cleanArgs.contains("--help") || cleanArgs.contains("-h") {
            return .help
        }
        if cleanArgs.contains("--simulate-e2e") {
            return .simulateE2E
        }
        if cleanArgs.contains("--live") {
            return .live
        }
        if let first = cleanArgs.first {
            return .invalid("Unknown argument '\(first)'. Run with --help for options.")
        }
        return .simulateE2E
    }
}

@main
struct AirPodWandMain {
    static func main() async {
        let mode = CLIArgsParser.parse(CommandLine.arguments)

        switch mode {
        case .help:
            printUsage()
            exit(0)

        case .simulateE2E:
            let success = await SimulationRunner.run()
            exit(success ? 0 : 1)

        case .live:
            do {
                try await LivePipeline.run()
                exit(0)
            } catch {
                fputs("AirPodWand live daemon error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case .invalid(let message):
            fputs("Error: \(message)\n\n", stderr)
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        OVERVIEW: AirPodWand macOS Driver & Gesture Controller

        USAGE: AirPodWandCLI [options]

        OPTIONS:
          --simulate-e2e    Run closed-loop synthetic verification session (default)
          --live            Run live CoreMotion hardware driver daemon
          --help, -h        Show this help message

        EXIT CODES:
          0    Verification passed or daemon shut down cleanly
          1    Verification failed or runtime initialization error
        """)
        fflush(stdout)
    }
}
