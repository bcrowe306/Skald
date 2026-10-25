#+build linux, darwin, freebsd, openbsd, netbsd
#+no-instrumentation
package skald

import "core:sys/posix"

// The calling thread's CPU time in nanoseconds (prof.odin's SPALL_CLOCK=cpu)
@(private)
thread_cpu_ns :: proc "contextless" () -> (u64, bool) {
	ts: posix.timespec
	if posix.clock_gettime(.THREAD_CPUTIME_ID, &ts) != .OK { return 0, false }
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec), true
}
