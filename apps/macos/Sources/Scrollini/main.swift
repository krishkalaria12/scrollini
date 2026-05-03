import Darwin
import Foundation

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--cleanup-watch" {
    guard let parentPID = pid_t(CommandLine.arguments[2]), parentPID > 0 else {
        fputs("scrollini: invalid cleanup watcher parent pid\n", stderr)
        exit(2)
    }
    CleanupWatcher.run(parentPID: parentPID, snapshotPath: CommandLine.arguments[3])
}

Scrollini().start()
