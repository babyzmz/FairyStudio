import Darwin

/// 当前进程内存占用（只读诊断）。
/// - residentBytes：`mach_task_basic_info.resident_size`（常驻内存）；
/// - footprintBytes：`task_vm_info.phys_footprint`（Xcode 内存仪表显示的口径）。
struct ProcessMemorySnapshot: Hashable, Sendable {
    var residentBytes: UInt64
    var footprintBytes: UInt64

    var residentMB: Double { Double(residentBytes) / 1_048_576 }
    var footprintMB: Double { Double(footprintBytes) / 1_048_576 }

    static func current() -> ProcessMemorySnapshot? {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        let footprint = vmResult == KERN_SUCCESS ? UInt64(vm.phys_footprint) : 0
        return ProcessMemorySnapshot(residentBytes: UInt64(basic.resident_size), footprintBytes: footprint)
    }
}
