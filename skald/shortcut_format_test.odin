package skald

import "core:testing"

// Chords read the way each platform writes them: "Ctrl+Shift+Z" on Windows and Linux,
// "Shift+Cmd+Z" on a Mac (Cmd is `.Super`, Option is `.Alt`, in the Mac's order)
@(test)
shortcut_format_names_keys_per_platform :: proc(t: ^testing.T) {
	testing.expect_value(t, shortcut_format_for({.Z, {.Ctrl, .Shift}}, false), "Ctrl+Shift+Z")
	testing.expect_value(t, shortcut_format_for({.F4, {.Alt}}, false), "Alt+F4")
	testing.expect_value(t, shortcut_format_for({.S, {.Super}}, false), "Super+S")
	testing.expect_value(t, shortcut_format_for({.S, {.Super}}, true), "Cmd+S")
	testing.expect_value(t, shortcut_format_for({.Z, {.Super, .Shift}}, true), "Shift+Cmd+Z")
	testing.expect_value(t, shortcut_format_for({.A, {.Ctrl, .Alt, .Shift, .Super}}, true), "Ctrl+Option+Shift+Cmd+A")
	testing.expect_value(t, shortcut_format_for({.Delete, {}}, true), "Del")
	// Every platform: the plain call is this platform's
	testing.expect_value(t, shortcut_format({.S, {PRIMARY_MODIFIER}}), ODIN_OS == .Darwin ? "Cmd+S" : "Ctrl+S")
}
