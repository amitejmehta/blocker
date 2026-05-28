// Scheduled app + website blocker for macOS.
//
// Build:   swiftc blocker.swift -o blocker
// Run:     ./blocker            (user mode: kills apps)
//          sudo ./blocker       (root mode: manages /etc/hosts)
//
// Config:  config.json next to the binary.
// Kill log: kills.log next to the binary (TSV: ISO-timestamp \t bundle-id).

import Foundation

let MARK_BEGIN = "# >>> blocker managed >>>"
let MARK_END   = "# <<< blocker managed <<<"
let POLL_INTERVAL: TimeInterval = 0.3
let HOSTS_PATH = "/etc/hosts"

struct Schedule: Decodable {
    let name: String
    let start: String
    let end: String
    let days: [Int]
    let apps: [String]
    let domains: [String]
}
struct Config: Decodable { let schedules: [Schedule] }

func baseDir() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
}
let CONFIG_URL = baseDir().appendingPathComponent("config.json")
let KILLS_URL  = baseDir().appendingPathComponent("kills.log")

func loadConfig() -> Config? {
    guard let data = try? Data(contentsOf: CONFIG_URL) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

func parseHM(_ s: String) -> (Int, Int)? {
    let p = s.split(separator: ":")
    guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
    return (h, m)
}

func activeSchedules(_ cfg: Config, now: Date = Date()) -> [Schedule] {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
    let wd = ((comps.weekday! + 5) % 7)  // 1=Sun..7=Sat -> 0=Mon..6=Sun
    let curMin = comps.hour! * 60 + comps.minute!
    return cfg.schedules.filter { sch in
        guard sch.days.contains(wd),
              let (sh, sm) = parseHM(sch.start),
              let (eh, em) = parseHM(sch.end) else { return false }
        return curMin >= sh * 60 + sm && curMin < eh * 60 + em
    }
}

func blockedNow(_ cfg: Config) -> (Set<String>, Set<String>) {
    var apps = Set<String>(), domains = Set<String>()
    for sch in activeSchedules(cfg) {
        apps.formUnion(sch.apps); domains.formUnion(sch.domains)
    }
    return (apps, domains)
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - App killing

var bundlePathCache: [String: String] = [:]
func bundlePath(for bid: String) -> String? {
    if let p = bundlePathCache[bid] { return p }
    let p = Process(); let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemCFBundleIdentifier == '\(bid)'"]
    p.standardOutput = out
    try? p.run(); p.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let lines = String(data: data, encoding: .utf8)?
        .split(separator: "\n").map(String.init) ?? []
    if let path = lines.first(where: { $0.hasSuffix(".app") }) {
        bundlePathCache[bid] = path
        return path
    }
    return nil
}

// MARK: - /etc/hosts

func renderHostsBlock(_ domains: Set<String>) -> String {
    guard !domains.isEmpty else { return "" }
    var lines = [MARK_BEGIN]
    for d in domains.sorted() {
        lines.append("0.0.0.0 \(d)")
        lines.append("0.0.0.0 www.\(d)")
    }
    lines.append(MARK_END)
    return lines.joined(separator: "\n") + "\n"
}

func updateHosts(_ domains: Set<String>) {
    guard getuid() == 0 else { return }
    let url = URL(fileURLWithPath: HOSTS_PATH)
    let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    var stripped = current
    if let bRange = current.range(of: MARK_BEGIN),
       let eRange = current.range(of: MARK_END) {
        let pre = String(current[..<bRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let post = String(current[eRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stripped = pre + "\n" + post + "\n"
    }
    let newBlock = renderHostsBlock(domains)
    let desired = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        + "\n" + (newBlock.isEmpty ? "" : "\n" + newBlock)
    if desired != current {
        try? desired.write(to: url, atomically: true, encoding: .utf8)
        shell("/usr/bin/dscacheutil", ["-flushcache"])
        shell("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
}

// MARK: - Kill log

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func appendKill(_ bid: String) {
    let line = "\(isoFormatter.string(from: Date()))\t\(bid)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: KILLS_URL.path) {
        if let h = try? FileHandle(forWritingTo: KILLS_URL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    } else {
        try? data.write(to: KILLS_URL)
    }
}

// MARK: - Main loop

let isRoot = (getuid() == 0)
FileHandle.standardOutput.write(
    "[blocker] started uid=\(getuid()) role=\(isRoot ? "hosts" : "apps")\n"
        .data(using: .utf8)!)

var lastDomains: Set<String>? = nil
// Bundles pkill killed on the previous tick; used to dedupe so that one
// open-then-killed event records as a single kill rather than one per tick.
var lastKilled: Set<String> = []

while true {
    if let cfg = loadConfig() {
        let (apps, domains) = blockedNow(cfg)
        if isRoot {
            if domains != lastDomains {
                updateHosts(domains); lastDomains = domains
            }
        } else {
            var killedThisTick: Set<String> = []
            for bid in apps {
                guard let path = bundlePath(for: bid) else { continue }
                if shell("/usr/bin/pkill", ["-9", "-f", path]) == 0 {
                    killedThisTick.insert(bid)
                    if !lastKilled.contains(bid) { appendKill(bid) }
                }
            }
            lastKilled = killedThisTick
        }
    }
    Thread.sleep(forTimeInterval: POLL_INTERVAL)
}
