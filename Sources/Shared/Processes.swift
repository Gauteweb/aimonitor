import Darwin
import Foundation

struct ProcessGroup {
    var count = 0
    var bytes: UInt64 = 0
    /// Total CPU time (user + system) so far, in nanoseconds, per process.
    var cpuTimes: [pid_t: UInt64] = [:]
}

/// Memory and CPU time of running processes, sorted into groups by each app.
struct ProcessUsage<Group: Hashable> {
    var groups: [Group: ProcessGroup] = [:]

    subscript(_ group: Group) -> ProcessGroup {
        get { groups[group] ?? ProcessGroup() }
        set { groups[group] = newValue }
    }
}

/// A running process, as shown to the function that sorts processes into groups.
struct RunningProcess {
    let pid: pid_t
    /// The executable's name, as in `proc_name`.
    let name: String
    /// The executable's full path.
    let path: String

    var isSelf: Bool { pid == getpid() }

    /// The first command-line argument. Some programs replace it with a readable
    /// process title, e.g. Vibe, which runs as `python3.13` but sets it to "Vibe CLI".
    func firstArgument() -> String? { arguments().first.flatMap { $0.isEmpty ? nil : $0 } }

    /// The command-line arguments, starting with the program name (argv[0]).
    func arguments() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        // Layout: argc, the executable path, padding zeros, then the arguments.
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The folder the process runs in, e.g. the project a CLI was started in.
    func workingDirectory() -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// When the process was started.
    func startTime() -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The memory footprint, the same figure as Activity Monitor's "Memory" column.
    func memoryFootprint() -> UInt64? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        return ok ? info.ri_phys_footprint : nil
    }
}

/// All running processes this user may inspect.
func runningProcesses() -> [RunningProcess] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var pathBuf = [CChar](repeating: 0, count: 4096)
    var result: [RunningProcess] = []
    for pid in pids.prefix(max(n, 0)) where pid > 0 {
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        result.append(RunningProcess(pid: pid, name: String(cString: nameBuf), path: String(cString: pathBuf)))
    }
    return result
}

/// `proc_pid_rusage` reports CPU time in Mach time units, which are only
/// nanoseconds on Intel Macs.
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/// Sums the memory footprint (same figure as Activity Monitor's "Memory" column)
/// of the processes `classify` puts in a group, and collects their CPU time.
/// Processes it returns nil for are left out.
func processUsage<Group: Hashable>(_ classify: (RunningProcess) -> Group?) -> ProcessUsage<Group> {
    var usage = ProcessUsage<Group>()
    for process in runningProcesses() {
        let pid = process.pid
        guard let group = classify(process) else { continue }

        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { continue }
        usage[group].count += 1
        usage[group].bytes += info.ri_phys_footprint
        let ticks = info.ri_user_time + info.ri_system_time
        usage[group].cpuTimes[pid] = ticks * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
    }
    return usage
}
