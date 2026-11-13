import Foundation
import Combine

@MainActor
class SchedulerService: ObservableObject {
    @Published var config: ScheduleConfig {
        didSet { saveConfig() }
    }

    private var timer: Timer?
    private let configKey = "Cachora.ScheduledScanConfig"
    private let defaults: UserDefaults?
    private var onTrigger: (() async -> Bool)?
    private var isRunningScan = false

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(ScheduleConfig.self, from: data) {
            config = saved
        } else {
            config = ScheduleConfig()
        }
    }

    func setTrigger(_ handler: @escaping () async -> Bool) {
        onTrigger = handler
    }

    func start() {
        stop()
        guard config.isEnabled else { return }

        let now = Date()
        if config.nextRunDate.map({ $0 > now }) != true {
            config.nextRunDate = now.addingTimeInterval(config.interval.seconds)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runIfDue()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateSchedule(interval: ScheduleInterval) {
        config.interval = interval
        if config.isEnabled {
            config.nextRunDate = Date().addingTimeInterval(interval.seconds)
        }
    }

    func toggleEnabled(_ enabled: Bool) {
        config.isEnabled = enabled
        if enabled {
            start()
        } else {
            config.nextRunDate = nil
            stop()
        }
    }

    func runIfDue(at now: Date = Date()) async {
        guard config.isEnabled, !isRunningScan,
              let nextRun = config.nextRunDate,
              now >= nextRun, let onTrigger else { return }

        isRunningScan = true
        defer { isRunningScan = false }
        guard await onTrigger(), config.isEnabled else { return }

        var updated = config
        updated.lastRunDate = now
        if updated.nextRunDate == nextRun {
            updated.nextRunDate = now.addingTimeInterval(updated.interval.seconds)
        }
        config = updated
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults?.set(data, forKey: configKey)
        }
    }

    // MARK: - LaunchAgent Management

    func installLaunchAgent() {
        let plistName = "com.puremac.scheduler"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName).plist")

        guard let appPath = Bundle.main.executablePath else { return }

        let intervalSeconds = Int(config.interval.seconds)
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistName)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(appPath)</string>
                <string>--scheduled-clean</string>
            </array>
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
            <key>RunAtLoad</key>
            <false/>
        </dict>
        </plist>
        """

        try? plistContent.write(to: plistPath, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["load", plistPath.path]
        try? task.run()
        task.waitUntilExit()
    }

    func uninstallLaunchAgent() {
        let plistName = "com.puremac.scheduler"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName).plist")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistPath.path]
        try? task.run()
        task.waitUntilExit()

        try? FileManager.default.removeItem(at: plistPath)
    }
}
