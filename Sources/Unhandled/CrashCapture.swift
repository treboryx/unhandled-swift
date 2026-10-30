#if canImport(Darwin)
import Darwin
import Foundation
import MachO

private let handledSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
private let alternateStackSize = 65536

// A constant initializer makes this static data, so reading it in the handler runs no lazy initialization.
nonisolated(unsafe) private var crashScratch: UnsafeMutablePointer<CrashScratch>? = nil

private let exceptionSink = Locked<(@Sendable (UncaughtException) -> Void)?>(nil)
private typealias ExceptionHandler = @convention(c) (NSException) -> Void
private let previousExceptionHandler = Locked<ExceptionHandler?>(nil)

private func faultingAddress(_ context: UnsafeMutableRawPointer?) -> UInt? {
    guard let machine = context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext else { return nil }
    #if arch(arm64)
    return UInt(machine.pointee.__ss.__pc)
    #elseif arch(x86_64)
    return UInt(machine.pointee.__ss.__rip)
    #else
    return nil
    #endif
}

private func restoreDefaultAction(_ signal: Int32) {
    var action = sigaction()
    sigemptyset(&action.sa_mask)
    sigaction(signal, &action, nil)
}

// A fault the CPU raised re-executes its instruction when the handler returns; one sent by kill or raise does not.
// Darwin sets si_code alike for both, so the fault address tells them apart; a fault at address 0 falls back to raise.
private func isHardwareFault(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?) -> Bool {
    guard signal == SIGSEGV || signal == SIGBUS || signal == SIGILL || signal == SIGFPE || signal == SIGTRAP else {
        return false
    }
    return info?.pointee.si_addr != nil
}

private func chainSignal(
    _ signal: Int32,
    _ info: UnsafeMutablePointer<__siginfo>?,
    _ context: UnsafeMutableRawPointer?,
    previous: UnsafeMutablePointer<sigaction>
) {
    // Restored first, so a fault that re-executes after a returning handler goes to the previous action, not here.
    sigaction(signal, previous, nil)
    let action = previous.pointee
    let bits = UInt(bitPattern: unsafeBitCast(action.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self))
    let isDefault = bits == 0
    let isIgnore = bits == 1
    if !isDefault, !isIgnore {
        if action.sa_flags & SA_SIGINFO != 0 {
            action.__sigaction_u.__sa_sigaction(signal, info, context)
        } else {
            action.__sigaction_u.__sa_handler(signal)
        }
        return
    }
    if isHardwareFault(signal, info) {
        // An ignored hardware fault would re-execute forever.
        if isIgnore { restoreDefaultAction(signal) }
        return
    }
    // Blocked until the handler returns, then delivered with the default action at the original context.
    if isDefault { raise(signal) }
}

private func handleSignal(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    guard let scratch = crashScratch, signal > 0, Int(signal) < CrashScratch.signalCapacity else {
        restoreDefaultAction(signal)
        raise(signal)
        return
    }
    let fd = scratch.pointee.fd
    if fd >= 0, scratch.pointee.exceptionReported == 0 {
        let count = backtrace(scratch.pointee.frames, Int32(CrashScratch.frameCapacity))
        let length = formatCrashReport(scratch, signal: signal, time: time(nil), pc: faultingAddress(context), frameCount: Int(count))
        _ = write(fd, scratch.pointee.text, length)
        var next = 0
        while next < scratch.pointee.imageCount {
            let imageLength = formatImageLines(scratch, from: &next)
            _ = write(fd, scratch.pointee.text, imageLength)
        }
    }
    chainSignal(signal, info, context, previous: scratch.pointee.previousActions + Int(signal))
}

private func imageAdded(_ header: UnsafePointer<mach_header>?, _: Int) {
    guard let header, let scratch = crashScratch else { return }
    var info = Dl_info()
    guard dladdr(header, &info) != 0, let name = info.dli_fname else { return }
    let index = scratch.pointee.imageCount
    guard index < CrashScratch.imageCapacity else {
        scratch.pointee.imagesDropped += 1
        return
    }
    let uuid = imageUUIDBytes(header: UnsafeRawPointer(header)).map { bytes in
        (0 ..< 16).reduce((high: UInt64(0), low: UInt64(0))) { value, offset in
            let byte = UInt64(bytes.load(fromByteOffset: offset, as: UInt8.self))
            return offset < 8 ? (value.high << 8 | byte, value.low) : (value.high, value.low << 8 | byte)
        }
    }
    scratch.pointee.images[index] = CrashImage(name: name, address: UInt64(UInt(bitPattern: header)), uuid: uuid)
    scratch.pointee.imageCount = index + 1
}

private func imageRemoved(_ header: UnsafePointer<mach_header>?, _: Int) {
    guard let header, let scratch = crashScratch else { return }
    let address = UInt64(UInt(bitPattern: header))
    for index in 0 ..< scratch.pointee.imageCount where scratch.pointee.images[index].address == address {
        scratch.pointee.images[index].name = nil
    }
}

private func handleUncaughtException(_ exception: NSException) {
    crashScratch?.pointee.exceptionReported = 1
    if let sink = exceptionSink.withLock({ $0 }) {
        let addresses = exception.callStackReturnAddresses.map { $0.uint64Value }
        sink(UncaughtException(
            object: exception,
            type: exception.name.rawValue,
            message: exception.reason ?? "",
            frames: liveFrames(addresses)
        ))
    }
    previousExceptionHandler.withLock { $0 }?(exception)
}

private func isOurs(_ action: sigaction) -> Bool {
    let handler = unsafeBitCast(action.__sigaction_u.__sa_sigaction, to: UnsafeRawPointer?.self)
    let ours: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = handleSignal
    return handler == unsafeBitCast(ours, to: UnsafeRawPointer?.self)
}

enum CrashCapture {
    private static let installed = Locked(false)

    static func install(
        directory: URL,
        onException: @escaping @Sendable (UncaughtException) -> Void
    ) -> NativeCrashHandlers? {
        guard installed.withLock({ wasInstalled in
            defer { wasInstalled = true }
            return !wasInstalled
        }) else { return nil }
        let scratch: UnsafeMutablePointer<CrashScratch>
        if let existing = crashScratch {
            scratch = existing
        } else {
            scratch = CrashScratch.allocate()
            crashScratch = scratch
            // dyld calls these for every image already loaded, then for each later dlopen; they cannot be unregistered.
            _dyld_register_func_for_add_image(imageAdded)
            _dyld_register_func_for_remove_image(imageRemoved)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let images = formatImages(main: mainExecutableName, images: loadedImages())
        try? Data(images.utf8).write(to: directory.appendingPathComponent(CrashFiles.images), options: .atomic)
        _ = backtrace(scratch.pointee.frames, 1)
        scratch.pointee.exceptionReported = 0
        scratch.pointee.fd = open(directory.appendingPathComponent(CrashFiles.report).path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        #if !os(tvOS) && !os(watchOS)
        // A stack overflow leaves no room to run the handler, so it runs on its own stack (this thread only).
        var current = stack_t()
        if sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE != 0 {
            var stack = stack_t(
                ss_sp: UnsafeMutableRawPointer.allocate(byteCount: alternateStackSize, alignment: 16),
                ss_size: alternateStackSize,
                ss_flags: 0
            )
            _ = sigaltstack(&stack, nil)
        }
        #endif
        for signal in handledSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = handleSignal
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, scratch.pointee.previousActions + Int(signal))
        }

        exceptionSink.withLock { $0 = onException }
        previousExceptionHandler.withLock { $0 = NSGetUncaughtExceptionHandler() }
        NSSetUncaughtExceptionHandler(handleUncaughtException)

        return NativeCrashHandlers {
            guard let scratch = crashScratch else { return }
            for signal in handledSignals {
                var action = sigaction()
                if sigaction(signal, nil, &action) == 0, isOurs(action) {
                    sigaction(signal, scratch.pointee.previousActions + Int(signal), nil)
                }
            }
            let handler: ExceptionHandler = handleUncaughtException
            let ours = unsafeBitCast(handler, to: UnsafeRawPointer.self)
            if let current = NSGetUncaughtExceptionHandler(), unsafeBitCast(current, to: UnsafeRawPointer.self) == ours {
                let previous = previousExceptionHandler.withLock { $0 }
                NSSetUncaughtExceptionHandler(previous)
            }
            exceptionSink.withLock { $0 = nil }
            let fd = scratch.pointee.fd
            scratch.pointee.fd = -1
            if fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(CrashFiles.report))
            installed.withLock { $0 = false }
        }
    }
}
#endif
