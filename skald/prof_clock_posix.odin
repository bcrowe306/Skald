#+build linux, darwin, freebsd, openbsd, netbsd
#+no-instrumentation
package skald

import "core:sys/posix"

// The trace's clocks (prof.odin), foreign calls only: with SPALL_AUTO an instrumented clock
// (core:time's) would enter the hooks, which read the clock, which enter the hooks...

// Wall time in nanoseconds (the monotonic clock)
@(private)
@(no_instrumentation)
wall_ns :: proc "contextless" () -> u64 {
	ts: posix.timespec
	_ = posix.clock_gettime(.MONOTONIC, &ts)
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}

// The calling thread's CPU time in nanoseconds (SPALL_CLOCK=cpu)
@(private)
@(no_instrumentation)
thread_cpu_ns :: proc "contextless" () -> (u64, bool) {
	ts: posix.timespec
	if posix.clock_gettime(.THREAD_CPUTIME_ID, &ts) != .OK { return 0, false }
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec), true
}
