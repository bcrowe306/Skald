#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+no-instrumentation
package skald

// No thread CPU clock here: prof.odin's SPALL_CLOCK=cpu falls back to wall time
@(private)
thread_cpu_ns :: proc "contextless" () -> (u64, bool) {
	return 0, false
}
