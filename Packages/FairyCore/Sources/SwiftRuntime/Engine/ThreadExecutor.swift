import Foundation
import Synchronization

/// 运行实例的活跃资源计数（测试用于断言 run/stop 后无泄漏）。每个引擎一份，互不干扰。
public final class RuntimeLiveCounters: Sendable {
    private let state = Mutex<(instances: Int, threads: Int, tasks: Int)>((0, 0, 0))
    public init() {}
    public var liveInstances: Int { state.withLock { $0.instances } }
    public var liveThreads: Int { state.withLock { $0.threads } }
    public var liveTasks: Int { state.withLock { $0.tasks } }
    func instanceCreated() { state.withLock { $0.instances += 1 } }
    func instanceDestroyed() { state.withLock { $0.instances -= 1 } }
    func threadStarted() { state.withLock { $0.threads += 1 } }
    func threadExited() { state.withLock { $0.threads -= 1 } }
    func taskStarted() { state.withLock { $0.tasks += 1 } }
    func taskEnded() { state.withLock { $0.tasks -= 1 } }
}

/// 运行实例 actor 的自定义串行执行器：一个专用线程（大栈），不占用 MainActor，也不长期占用协作线程池。
///
/// 解释器是同步执行的；把它放在专用线程上可以使用较大的栈（嵌套回调、深层视图树），
/// 而 stop() 通过原子取消标志与之协作（见 CancelToken）。
///
/// `@unchecked Sendable` 的理由：所有可变状态（队列、标志、等待者）只在 `cond` 锁内访问。
final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let cond = NSCondition()
    private var queue: [UnownedJob] = []
    private var threadRunning = false
    private var shutdownRequested = false
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []
    private let stackSize: Int
    private let name: String
    private let counters: RuntimeLiveCounters

    init(name: String, stackSize: Int = 32 << 20, counters: RuntimeLiveCounters) {
        self.name = name
        self.stackSize = stackSize
        self.counters = counters
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let j = UnownedJob(job)
        cond.lock()
        queue.append(j)
        if !threadRunning {
            threadRunning = true
            startThread()
        }
        cond.signal()
        cond.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    private func startThread() {
        counters.threadStarted()
        let t = Thread { [self] in self.threadMain() }
        t.stackSize = stackSize
        t.name = name
        t.start()
    }

    private func threadMain() {
        while true {
            cond.lock()
            while queue.isEmpty && !shutdownRequested { cond.wait() }
            if queue.isEmpty {
                threadRunning = false
                let waiters = joinWaiters
                joinWaiters = []
                cond.unlock()
                counters.threadExited()
                for w in waiters { w.resume() }
                return
            }
            let job = queue.removeFirst()
            cond.unlock()
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    /// 请求线程在队列清空后退出（之后若再有任务入队，会按需重新启动线程）。
    func requestShutdown() {
        cond.lock()
        shutdownRequested = true
        cond.broadcast()
        cond.unlock()
    }

    /// 等待线程退出。
    func join() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            cond.lock()
            if !threadRunning {
                cond.unlock()
                c.resume()
            } else {
                joinWaiters.append(c)
                cond.unlock()
            }
        }
    }
}

/// 在大栈线程上同步执行一个闭包（validate 的编译阶段使用，避免深层语法树耗尽协作线程的栈）。
enum BigStack {
    static func run<T: Sendable>(stackSize: Int = 32 << 20, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let t = Thread { c.resume(returning: body()) }
            t.stackSize = stackSize
            t.name = "FairyRuntime.compile"
            t.start()
        }
    }
}
