#+no-instrumentation
package skald

import "base:runtime"
import "core:os"
import "core:prof/spall"
import "core:sync"

// Profiling with Spall (https://gravitymoth.com/spall/), compiled out unless asked for.
//
// Build with `-define:SPALL=true` and every `prof_scope` below becomes a begin / end pair in a
// `.spall` trace; without it they are empty procedures the optimizer removes, so normal builds
// pay nothing. `-define:SPALL_AUTO=true` (with SPALL) also records every procedure of the
// program through Odin's instrumentation hooks: far more detail, far slower, for finding hot
// spots that no scope names yet.
//
// The trace:
//   - `skald.run` starts one when none is running (`prof_start`), named by the `SPALL_TRACE`
//     environment variable (default `trace.spall` in the working folder), and stops it when the
//     loop ends. An app can start it earlier itself, and stop it later (before `os.exit`).
//   - **The clock:** wall time by default (how long things took, waits included). With
//     `SPALL_CLOCK=cpu` each thread's own CPU time instead (POSIX's thread CPU clock; wall time
//     on Windows): time the thread spent descheduled, waiting on the GPU or sleeping isn't
//     counted, so CPU work can be compared while other programs load the machine. Each thread's
//     timeline is then its own.
//   - Each thread writes into its own buffer, made the first time it records something and
//     flushed when it's full, when the thread ends (`prof_thread_end`: `cmd_thread`'s workers
//     call it) or when the trace stops. Skald writes the events and the buffers itself (not
//     through spall's buffer procedures, whose flush stamps a wall-clock event).
//   - Another library records into the same trace by calling `prof_begin` / `prof_end` (the
//     Crossfire engine's `Trace_Share` takes them), so one thread's events from both nest, on
//     one clock.
//
// Scopes in the frame loop (app.odin): `frame` (one rendered frame: view, layout and draw,
// overlays, GPU submit, update), inside it `view`, `render_view`, `render_overlays`,
// `frame_begin`, `frame_end`, `update`; outside it `events` (the event pump and the queues), `idle`
// (waiting for events) and `pace` (the MAILBOX frame-rate sleep).

// SPALL turns profiling on (`-define:SPALL=true`).
SPALL :: #config(SPALL, false)

// SPALL_AUTO records every procedure (`-define:SPALL_AUTO=true`, with SPALL).
SPALL_AUTO :: #config(SPALL_AUTO, false)

// PROF_BUFFER_SIZE is the size of each thread's buffer: a full buffer is written to the file.
PROF_BUFFER_SIZE :: 1 << 20

// Every procedure here is @(no_instrumentation) (the file tag alone left them instrumented), and
// the ones slicing a buffer are #no_bounds_check: the runtime's bounds-check helpers are inlined
// with SPALL_AUTO's hooks, which would call back into prof_begin forever (spall's own code says
// so too)
@(private="file") profCtx: spall.Context
@(private="file") profRunning: bool
// SPALL_CLOCK=cpu: timestamps are the thread's CPU time
@(private="file") profCPUClock: bool
@(private="file") profLock: sync.Mutex
// Held while a buffer is written to the file (threads flush on their own)
@(private="file") profWriteLock: sync.Mutex
@(private="file") profBuffers: [dynamic]^spall.Buffer
@(private="file") @(thread_local) profBuffer: ^spall.Buffer
// Set while a thread makes or frees its buffer: allocating runs instrumented procedures
// (SPALL_AUTO), which would ask for the buffer again or write into one being freed.
@(private="file") @(thread_local) profBusy: bool

/*
Starts the trace, writing to `path` (the `SPALL_TRACE` environment variable when empty, else
`trace.spall`), on the clock `SPALL_CLOCK` names (`cpu`: each thread's CPU time; else wall time).
Does nothing without SPALL, or when a trace is already running.

Returns:
- true when a trace is running afterwards
*/
@(no_instrumentation)
prof_start :: proc(path := "") -> bool {
	when SPALL {
		if profRunning { return true }
		file := path
		if file == "" { file = os.get_env("SPALL_TRACE", context.temp_allocator) }
		if file == "" { file = "trace.spall" }
		// Timestamps in nanoseconds (scale 1): no two-second clock calibration at startup
		ctx, ok := spall.context_create_with_scale(file, false, 1)
		if !ok { return false }
		profCtx = ctx
		profCPUClock = os.get_env("SPALL_CLOCK", context.temp_allocator) == "cpu"
		profRunning = true
		prof_name_thread("main")
		return true
	} else {
		return false
	}
}

/*
Stops the trace: every thread's buffer is written and freed, and the file closed. Threads still
recording must have finished (workers end with `prof_thread_end`).
*/
@(no_instrumentation)
prof_stop :: proc() {
	when SPALL {
		if !profRunning { return }
		profBusy = true
		defer profBusy = false
		profBuffer = nil
		sync.lock(&profLock)
		for b in profBuffers {
			bufferWrite(b)
			bufferFree(b)
		}
		delete(profBuffers)
		profBuffers = nil
		sync.unlock(&profLock)
		profRunning = false
		spall.context_destroy(&profCtx)
	}
}

// prof_running says whether a trace is being written.
@(no_instrumentation)
prof_running :: proc "contextless" () -> bool {
	when SPALL { return profRunning } else { return false }
}

// prof_now is the trace's clock: nanoseconds of wall time, or of the thread's CPU time with SPALL_CLOCK=cpu.
@(no_instrumentation)
prof_now :: proc "contextless" () -> u64 {
	if profCPUClock {
		if ns, ok := thread_cpu_ns(); ok { return ns }
	}
	return wall_ns()
}

// The calling thread's buffer, made the first time (nil without a running trace)
@(private="file")
@(no_instrumentation)
threadBuffer :: proc "contextless" () -> ^spall.Buffer {
	when SPALL {
		if profBusy { return nil }
		if profBuffer != nil || !profRunning { return profBuffer }
		profBusy = true
		defer profBusy = false
		context = runtime.default_context()
		data, err := make([]u8, PROF_BUFFER_SIZE, runtime.heap_allocator())
		if err != nil { return nil }
		b := new(spall.Buffer, runtime.heap_allocator())
		b^ = spall.buffer_create(data, u32(sync.current_thread_id()), u32(os.get_pid()))
		b.first_ts = prof_now()
		sync.lock(&profLock)
		append(&profBuffers, b)
		sync.unlock(&profLock)
		profBuffer = b
		return b
	} else {
		return nil
	}
}

/*
Writes and frees the calling thread's buffer: call it before a thread that recorded ends (Skald's
`cmd_thread` workers do). The thread gets a new buffer if it records again.
*/
@(no_instrumentation)
prof_thread_end :: proc "contextless" () {
	when SPALL {
		b := profBuffer
		if b == nil { return }
		profBusy = true
		defer profBusy = false
		profBuffer = nil
		context = runtime.default_context()
		sync.lock(&profLock)
		for x, i in profBuffers {
			if x == b { unordered_remove(&profBuffers, i); break }
		}
		sync.unlock(&profLock)
		if profRunning { bufferWrite(b) }
		bufferFree(b)
	}
}

// prof_name_thread names the calling thread in the trace.
@(no_instrumentation)
prof_name_thread :: proc "contextless" (name: string) #no_bounds_check {
	when SPALL {
		if b := threadBuffer(); b != nil {
			if b.head + spall.NAME_EVENT_MAX > len(b.data) { bufferWrite(b) }
			b.head += spall._build_name_event(b.data[b.head:], name, .Name_Thread)
		}
	}
}

/*
Begins a named span on the calling thread; `prof_end` ends the innermost one. Prefer
`prof_scope`, which ends itself.
*/
@(no_instrumentation)
prof_begin :: proc "contextless" (name: string, args := "") #no_bounds_check {
	when SPALL {
		if b := threadBuffer(); b != nil {
			if b.head + spall.BEGIN_EVENT_MAX > len(b.data) { bufferWrite(b) }
			b.head += spall._build_begin(b.data[b.head:], name, args, prof_now())
		}
	}
}

// prof_end ends the calling thread's innermost span.
@(no_instrumentation)
prof_end :: proc "contextless" () #no_bounds_check {
	when SPALL {
		if b := threadBuffer(); b != nil {
			ts := prof_now()
			if b.head + size_of(spall.End_Event) > len(b.data) { bufferWrite(b) }
			b.head += spall._build_end(b.data[b.head:], ts)
		}
	}
}

/*
A span from here to the end of the enclosing block.

Example:
	@(no_instrumentation)
	draw_things :: proc() {
		prof_scope("draw_things")
		// ...
	}
*/
@(deferred_none = prof_end)
@(no_instrumentation)
prof_scope :: proc "contextless" (name: string, args := "") {
	prof_begin(name, args)
}

// Writes a buffer's events to the file and empties it (spall's buffer_flush, without the
// wall-clock "flush" event it adds)
@(private="file")
@(no_instrumentation)
bufferWrite :: proc "contextless" (b: ^spall.Buffer) #no_bounds_check {
	if len(b.data) == 0 || b.head <= size_of(spall.Manual_Buffer_Header) { return }
	// Locking and writing run instrumented procedures (SPALL_AUTO): no recording meanwhile
	was := profBusy
	profBusy = true
	defer profBusy = was
	hdr := (^spall.Manual_Buffer_Header)(raw_data(b.data))
	hdr.size = u32le(b.head - size_of(spall.Manual_Buffer_Header))
	hdr.pid = u32le(b.pid)
	hdr.tid = u32le(b.tid)
	hdr.first_ts = u64le(b.first_ts)
	context = runtime.default_context()
	sync.lock(&profWriteLock)
	_, _ = os.write(profCtx.file, b.data[:b.head])
	sync.unlock(&profWriteLock)
	b.head = size_of(spall.Manual_Buffer_Header)
	b.first_ts = prof_now()
}

@(private="file")
@(no_instrumentation)
bufferFree :: proc "contextless" (b: ^spall.Buffer) {
	context = runtime.default_context()
	delete(b.data, runtime.heap_allocator())
	free(b, runtime.heap_allocator())
}

when SPALL && SPALL_AUTO {
	// Every procedure of the program, named by its source location's procedure (Odin calls these
	// around each procedure without @(no_instrumentation) or a #+no-instrumentation file)
	@(instrumentation_enter)
	prof_auto_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		prof_begin(loc.procedure)
	}

	@(instrumentation_exit)
	prof_auto_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		prof_end()
	}
}
