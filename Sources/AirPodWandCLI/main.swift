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

/// Options configuring `--live` handheld AirPod cursor mode.
public struct LiveOptions: Sendable, Equatable {
    public var sensitivity: Double
    public var quickCalibrate: Bool
    public var invertX: Bool
    public var invertY: Bool
    public var enableDwellClick: Bool

    public init(
        sensitivity: Double = 1.0,
        quickCalibrate: Bool = false,
        invertX: Bool = false,
        invertY: Bool = false,
        enableDwellClick: Bool = true
    ) {
        self.sensitivity = sensitivity
        self.quickCalibrate = quickCalibrate
        self.invertX = invertX
        self.invertY = invertY
        self.enableDwellClick = enableDwellClick
    }
}

/// Command-line argument parser for AirPodWandCLI.
public struct CLIArgsParser: Sendable {
    public static func parse(_ args: [String]) -> CLIMode {
        parseDetailed(args).mode
    }

    public static func parseDetailed(_ args: [String]) -> (mode: CLIMode, options: LiveOptions) {
        let cleanArgs = Array(args.dropFirst())
        if cleanArgs.isEmpty {
            return (.simulateE2E, LiveOptions())
        }
        if cleanArgs.contains("--help") || cleanArgs.contains("-h") {
            return (.help, LiveOptions())
        }

        var hasSimulate = false
        var hasLive = false
        var hasLiveOption = false
        var options = LiveOptions()
        var firstNonFlagToken: String? = nil

        var index = 0
        while index < cleanArgs.count {
            let arg = cleanArgs[index]
            switch arg {
            case "--simulate-e2e":
                hasSimulate = true
            case "--live":
                hasLive = true
            case "--quick-calibrate":
                options.quickCalibrate = true
                hasLiveOption = true
            case "--invert-x":
                options.invertX = true
                hasLiveOption = true
            case "--invert-y":
                options.invertY = true
                hasLiveOption = true
            case "--no-dwell":
                options.enableDwellClick = false
                hasLiveOption = true
            case "--sensitivity":
                guard index + 1 < cleanArgs.count else {
                    return (.invalid("Missing value for '--sensitivity'. Provide a number between 0.1 and 5.0."), options)
                }
                index += 1
                let rawValue = cleanArgs[index]
                guard let parsed = Double(rawValue), parsed.isFinite, parsed >= 0.1, parsed <= 5.0 else {
                    return (.invalid("Invalid '--sensitivity' value '\(rawValue)'. Expected a number between 0.1 and 5.0."), options)
                }
                options.sensitivity = parsed
                hasLiveOption = true
            case _ where arg.hasPrefix("--sensitivity="):
                let rawValue = String(arg.dropFirst("--sensitivity=".count))
                guard let parsed = Double(rawValue), parsed.isFinite, parsed >= 0.1, parsed <= 5.0 else {
                    return (.invalid("Invalid '--sensitivity' value '\(rawValue)'. Expected a number between 0.1 and 5.0."), options)
                }
                options.sensitivity = parsed
                hasLiveOption = true
            default:
                if arg.hasPrefix("-") {
                    return (.invalid("Unknown argument '\(arg)'. Run with --help for options."), options)
                } else if firstNonFlagToken == nil {
                    firstNonFlagToken = arg
                }
            }
            index += 1
        }

        if hasSimulate && hasLive {
            return (.invalid("Cannot combine '--simulate-e2e' and '--live'."), options)
        }
        if hasSimulate {
            return (.simulateE2E, options)
        }
        if hasLive {
            return (.live, options)
        }
        if hasLiveOption {
            return (.invalid("Live tuning flags require '--live'. Run with --help for options."), options)
        }
        if let first = firstNonFlagToken {
            return (.invalid("Unknown argument '\(first)'. Run with --help for options."), options)
        }
        return (.simulateE2E, options)
    }
}

@main
struct AirPodWandMain {
    static func main() async {
        let (mode, liveOptions) = CLIArgsParser.parseDetailed(CommandLine.arguments)

        switch mode {
        case .help:
            printUsage()
            exit(0)

        case .simulateE2E:
            let success = await SimulationRunner.run()
            exit(success ? 0 : 1)

        case .live:
            do {
                let cursorSink = CGEventCursorSink()
                let displayBounds = await cursorSink.activeDisplayBounds()
                let engineConfig = EngineConfig.liveHandheld(
                    sensitivity: liveOptions.sensitivity,
                    screenWidthPx: Double(displayBounds.width),
                    requireUpTiltGesture: !liveOptions.quickCalibrate,
                    invertX: liveOptions.invertX,
                    invertY: liveOptions.invertY,
                    enableHoverDwellClick: liveOptions.enableDwellClick
                )
                print("[AirPodWand] Live config: sensitivity=\(String(format: "%.2f", liveOptions.sensitivity))x, displayWidth=\(Int(displayBounds.width))pt, guidedTilt=\(!liveOptions.quickCalibrate), invertX=\(liveOptions.invertX), invertY=\(liveOptions.invertY), dwell=\(liveOptions.enableDwellClick)")
                try await LivePipeline.run(
                    cursorSink: cursorSink,
                    engineConfig: engineConfig
                )
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
          --simulate-e2e          Run closed-loop synthetic verification session (default)
          --live                  Run live CoreMotion hardware driver daemon
          --sensitivity <0.1..5>  Cursor speed multiplier in --live mode (default: 1.0)
          --quick-calibrate       Skip Step 2 upward tilt and lock immediately after stillness
          --invert-x              Invert horizontal cursor direction in --live mode
          --invert-y              Invert vertical cursor direction in --live mode
          --no-dwell              Disable hover-dwell auto-clicking in --live mode
          --help, -h              Show this help message

        EXIT CODES:
          0    Verification passed or daemon shut down cleanly
          1    Verification failed or runtime initialization error
        """)
        fflush(stdout)
    }
}
