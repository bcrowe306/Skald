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
//   - Each thread writes into its own buffer, made the first time it records something and
//     flushed when it's full, when the thread ends (`prof_thread_end`: `cmd_thread`'s workers
//     call it) or when the trace stops.
//   - Another library can record into the same trace and the same per-thread buffers: hand it
//     `prof_context()` and `prof_thread_buffer` (the Crossfire engine's `Prof_Share`), so one
//     thread's events from both nest correctly.
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

@(private="file") profCtx: spall.Context
@(private="file") profRunning: bool
@(private="file") profLock: sync.Mutex
@(private="file") profBuffers: [dynamic]^spall.Buffer
@(private="file") @(thread_local) profBuffer: ^spall.Buffer
// Set while a thread makes its buffer: allocating runs instrumented procedures (SPALL_AUTO),
// which would ask for the buffer again.
@(private="file") @(thread_local) profBusy: bool

/*
Starts the trace, writing to `path` (the `SPALL_TRACE` environment variable when empty, else
`trace.spall`). Does nothing without SPALL, or when a trace is already running.

Returns:
- true when a trace is running afterwards
*/
prof_start :: proc(path := "") -> bool {
	when SPALL {
		if profRunning { return true }
		file := path
		if file == "" { file = os.get_env("SPALL_TRACE", context.temp_allocator) }
		if file == "" { file = "trace.spall" }
		// Ticks in nanoseconds (scale 1): no two-second clock calibration at startup
		ctx, ok := spall.context_create_with_scale(file, false, 1)
		if !ok { return false }
		profCtx = ctx
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
prof_stop :: proc() {
	when SPALL {
		if !profRunning { return }
		// No recording while the buffers go (freeing runs instrumented procedures)
		profBusy = true
		defer profBusy = false
		profBuffer = nil
		sync.lock(&profLock)
		for b in profBuffers {
			spall.buffer_destroy(&profCtx, b)
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
prof_running :: proc "contextless" () -> bool {
	when SPALL { return profRunning } else { return false }
}

// prof_context is the running trace (nil without one), for a library recording into it.
prof_context :: proc "contextless" () -> ^spall.Context {
	when SPALL {
		return &profCtx if profRunning else nil
	} else {
		return nil
	}
}

/*
The calling thread's buffer, made the first time (nil without a running trace). Other libraries
recording into the trace take this procedure, so a thread has one buffer for all of them.
*/
prof_thread_buffer :: proc "contextless" () -> ^spall.Buffer {
	when SPALL {
		if profBusy { return nil }
		if profBuffer != nil || !profRunning { return profBuffer }
		profBusy = true
		defer profBusy = false
		context = runtime.default_context()
		size := PROF_BUFFER_SIZE
		data, err := make([]u8, size, runtime.heap_allocator())
		if err != nil { return nil }
		b := new(spall.Buffer, runtime.heap_allocator())
		b^ = spall.buffer_create(data, u32(sync.current_thread_id()), u32(os.get_pid()))
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
		if profRunning { spall.buffer_destroy(&profCtx, b) }
		bufferFree(b)
	}
}

// prof_name_thread names the calling thread in the trace.
prof_name_thread :: proc "contextless" (name: string) {
	when SPALL {
		if b := prof_thread_buffer(); b != nil {
			spall._buffer_name_thread(&profCtx, b, name)
		}
	}
}

/*
Begins a named span on the calling thread; `prof_end` ends the innermost one. Prefer
`prof_scope`, which ends itself.
*/
prof_begin :: proc "contextless" (name: string, args := "") {
	when SPALL {
		if b := prof_thread_buffer(); b != nil {
			spall._buffer_begin(&profCtx, b, name, args)
		}
	}
}

// prof_end ends the calling thread's innermost span.
prof_end :: proc "contextless" () {
	when SPALL {
		if b := prof_thread_buffer(); b != nil {
			spall._buffer_end(&profCtx, b)
		}
	}
}

/*
A span from here to the end of the enclosing block.

Example:
	draw_things :: proc() {
		prof_scope("draw_things")
		// ...
	}
*/
@(deferred_none = prof_end)
prof_scope :: proc "contextless" (name: string, args := "") {
	prof_begin(name, args)
}

@(private="file")
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
		if b := prof_thread_buffer(); b != nil {
			spall._buffer_begin(&profCtx, b, "", "", loc)
		}
	}

	@(instrumentation_exit)
	prof_auto_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		if b := prof_thread_buffer(); b != nil {
			spall._buffer_end(&profCtx, b)
		}
	}
}
