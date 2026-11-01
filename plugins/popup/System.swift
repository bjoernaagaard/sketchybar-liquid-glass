import AppKit
import IOKit

// How strained a reading is. The bar and the system popup tint the same way.
enum Strain: String {
    case normal, warn, crit
}

enum MemoryPressure: Int32 {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var strain: Strain {
        switch self {
        case .normal: .normal
        case .warning: .warn
        case .critical: .crit
        }
    }
}

// Cumulative CPU ticks since boot. The kernel counters are 32-bit and wrap, so differences wrap too.
struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32

    // Like Activity Monitor and SketchyBar's cpu_load, nice time is left out.
    func load(since earlier: CPUTicks) -> CPULoad {
        let user = Double(user &- earlier.user), system = Double(system &- earlier.system)
        let total = user + system + Double(idle &- earlier.idle)
        return total > 0 ? CPULoad(user: user / total, system: system / total) : CPULoad(user: 0, system: 0)
    }
}

// Fractions of the interval, from 0 to 1.
struct CPULoad: Equatable {
    let user: Double
    let system: Double
    var total: Double { user + system }
}

// Activity Monitor's Memory Used is App + Wired + Compressed.
struct MemoryUsage: Equatable {
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let total: UInt64
    var used: UInt64 { app + wired + compressed }
}

struct Capacity: Equatable {
    let used: UInt64
    let total: UInt64
}

struct InterfaceBytes {
    let received: UInt32
    let sent: UInt32
}

struct NetworkRate: Equatable {
    let interface: String
    let received: Double
    let sent: Double
}

struct CoreCluster: Equatable {
    let title: String
    let load: Double
}

struct ProcessLoad {
    let name: String
    let percent: Int
}

// Unprivileged public reads. Unsafe Mach, sysctl, getifaddrs, IOKit, and libproc access stays here.
struct SystemRead {
    static let host = mach_host_self()

    static func number<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && size == MemoryLayout<T>.size ? value : nil
    }

    static func text(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func cpu() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2)
    }

    static func cores() -> [CPUTicks] {
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let values = UnsafeBufferPointer(start: info, count: Int(count))
        let stride = Int(CPU_STATE_MAX)
        guard values.count >= Int(cpus) * stride else { return [] }
        return (0..<Int(cpus)).map { cpu in
            let base = cpu * stride
            return CPUTicks(user: UInt32(bitPattern: values[base + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: values[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: values[base + Int(CPU_STATE_IDLE)]))
        }
    }

    // Apple silicon numbers its logical CPUs by cluster with efficiency cores first, which the
    // device tree's cluster-type confirms. Titles and counts come from hw.perflevel*.
    static let clusters: [(title: String, cpus: Range<Int>)] = {
        let levels = number("hw.nperflevels", Int32(0)) ?? 0
        guard levels > 1 else {
            let count = Int(number("hw.logicalcpu", Int32(0)) ?? 0)
            return [("Cores (\(count))", 0..<count)]
        }
        var start = 0
        return (0..<levels).reversed().map { level in
            let count = Int(number("hw.perflevel\(level).logicalcpu", Int32(0)) ?? 0)
            let name = text("hw.perflevel\(level).name") ?? "Level \(level)"
            defer { start += count }
            return ("\(name) cores (\(count))", start..<start + count)
        }.reversed()
    }()

    static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : 16384
    }()

    static func memory() -> MemoryUsage? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let app = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        return MemoryUsage(app: app * pageSize, wired: UInt64(info.wire_count) * pageSize,
                           compressed: UInt64(info.compressor_page_count) * pageSize, total: ProcessInfo.processInfo.physicalMemory)
    }

    static func pressure() -> MemoryPressure {
        number("kern.memorystatus_vm_pressure_level", Int32(0)).flatMap(MemoryPressure.init) ?? .normal
    }

    static func swap() -> Capacity? {
        number("vm.swapusage", xsw_usage()).map { Capacity(used: $0.xsu_used, total: $0.xsu_total) }
    }

    static func disk() -> Capacity? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let block = UInt64(stats.f_bsize)
        return Capacity(used: (stats.f_blocks - stats.f_bavail) * block, total: stats.f_blocks * block)
    }

    static func bytes(_ interface: String) -> InterfaceBytes? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data, String(cString: entry.pointee.ifa_name) == interface else { continue }
            let counters = data.load(as: if_data.self)
            return InterfaceBytes(received: counters.ifi_ibytes, sent: counters.ifi_obytes)
        }
        return nil
    }

    static func bootTime() -> Date? {
        number("kern.boottime", timeval()).map { Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_usec) / 1_000_000) }
    }

    // The highest utilization any GPU reports.
    static func gpu() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Int?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let statistics = property.takeRetainedValue() as? [String: Any],
                  let value = statistics["Device Utilization %"] as? Int else { continue }
            result = max(result ?? 0, value)
        }
        return result
    }

    // rusage times are in Mach time units, which are not nanoseconds on Apple silicon.
    static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        return mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }()

    // CPU time in nanoseconds for each process the user owns. Other users' processes are not readable.
    static func processTimes() -> [pid_t: Double] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [:] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [:] }
        let user = getuid()
        var times: [pid_t: Double] = [:]
        for pid in pids.prefix(min(count, capacity)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == user else { continue }
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0 else { continue }
            times[pid] = Double(usage.ri_user_time + usage.ri_system_time) * nanosecondsPerTick
        }
        return times
    }

    static func processName(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "Process \(pid)" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// One reading every 2 s. The bar shows CPU and memory from it, and the open popup shows all of it.
struct SystemSample: Equatable {
    let time: UInt64
    let cpu: CPULoad
    let clusters: [CoreCluster]
    let memory: MemoryUsage
    let pressure: MemoryPressure
    let swap: Capacity?
    let disk: Capacity?
    let network: NetworkRate?
    let thermal: ProcessInfo.ThermalState
    // CPU above 80 % for 5 samples in a row, which is 10 s.
    let busy: Bool

    var cpuStrain: Strain { thermal == .serious || thermal == .critical ? .crit : busy ? .warn : .normal }
    var diskStrain: Strain { disk.map { $0.total > 0 && ($0.total - $0.used) * 10 < $0.total } == true ? .warn : .normal }

    var bar: BarState {
        .system(cpu: Int((cpu.total * 100).rounded()),
                memory: memory.total > 0 ? Int((Double(memory.used) * 100 / Double(memory.total)).rounded()) : 0,
                cpuStrain: cpuStrain, memoryStrain: pressure.strain, diskStrain: diskStrain)
    }
}

// Keeps the previous counters, because CPU load and network speed are differences over time.
struct SystemSampler {
    private var time: UInt64 = 0
    private var cpu: CPUTicks?
    private var cores: [CPUTicks] = []
    private var network: (interface: String, bytes: InterfaceBytes)?
    private var busySamples = 0

    // The first call only primes the counters.
    mutating func sample(interface: String?) -> SystemSample? {
        let now = SystemRead.now()
        let ticks = SystemRead.cpu(), cores = SystemRead.cores()
        let bytes = interface.flatMap(SystemRead.bytes)
        defer {
            time = now
            cpu = ticks
            self.cores = cores
            if let interface, let bytes { network = (interface, bytes) } else { network = nil }
        }
        guard let ticks, let previous = cpu, now > time, let memory = SystemRead.memory() else { return nil }
        let load = ticks.load(since: previous)
        busySamples = load.total > 0.8 ? busySamples + 1 : 0
        let clusters = cores.count == self.cores.count ? SystemRead.clusters.compactMap { cluster -> CoreCluster? in
            let range = cluster.cpus.clamped(to: 0..<cores.count)
            guard !range.isEmpty else { return nil }
            let total = range.reduce(0) { $0 + cores[$1].load(since: self.cores[$1]).total }
            return CoreCluster(title: cluster.title, load: total / Double(range.count))
        } : []
        var rate: NetworkRate?
        if let interface, let bytes, let network, network.interface == interface {
            let seconds = Double(now - time) / 1_000_000_000
            rate = NetworkRate(interface: interface, received: Double(bytes.received &- network.bytes.received) / seconds,
                               sent: Double(bytes.sent &- network.bytes.sent) / seconds)
        }
        return SystemSample(time: now, cpu: load, clusters: clusters, memory: memory, pressure: SystemRead.pressure(),
                            swap: SystemRead.swap(), disk: SystemRead.disk(), network: rate,
                            thermal: ProcessInfo.processInfo.thermalState, busy: busySamples >= 5)
    }
}

// Top processes by CPU since the previous call. Read only while the system popup is open.
struct ProcessSampler {
    private var time: UInt64 = 0
    private var times: [pid_t: Double] = [:]

    mutating func sample(count: Int) -> [ProcessLoad]? {
        let now = SystemRead.now()
        let current = SystemRead.processTimes()
        defer { time = now; times = current }
        guard time > 0, now > time else { return nil }
        let elapsed = Double(now - time)
        return current.compactMap { pid, cpu in times[pid].flatMap { cpu >= $0 ? (pid, (cpu - $0) / elapsed) : nil } }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { ProcessLoad(name: SystemRead.processName($0.0), percent: Int(($0.1 * 100).rounded())) }
    }
}
