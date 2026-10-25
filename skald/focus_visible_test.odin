package skald

import "core:testing"

// Focus rings follow the keyboard (focus_visible: Tab shows them, a press hides them), and a
// dialog's Enter confirms unless the focused widget takes Enter itself.

@(private = "file")
FV_Msg :: enum { None, Dismiss, Confirm, Click }

@(test)
focus_ring_shows_after_tab_and_hides_after_a_press :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	a, b := hash_id("fv-a"), hash_id("fv-b")
	append(&ws.focusables, Focusable_Entry{id = a}, Focusable_Entry{id = b})
	testing.expect(t, !ws.focus_visible, "no ring before the keyboard moves focus")
	input: Input
	input.keys_pressed = {.Tab}
	widget_store_begin_frame(&ws, input)
	testing.expect_value(t, ws.focused_id, a)
	testing.expect(t, ws.focus_visible, "Tab shows the ring")
	input = {}
	input.mouse_pressed[.Left] = true
	widget_store_blur_on_outside_press(&ws, input)
	testing.expect(t, !ws.focus_visible, "a press hides it")
	// Tab again (the frame's focusables built again): back on
	append(&ws.focusables, Focusable_Entry{id = a}, Focusable_Entry{id = b})
	input = {}
	input.keys_pressed = {.Tab}
	widget_store_begin_frame(&ws, input)
	testing.expect(t, ws.focus_visible, "Tab shows it again")
}

@(test)
dialog_enter_confirms_unless_the_focus_takes_it :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	msgs: [dynamic]FV_Msg
	defer delete(msgs)
	input: Input
	field, ok := hash_id("fv-field"), hash_id("fv-ok")
	frame :: proc(ws: ^Widget_Store, th: ^Theme, lb: ^Labels, input: ^Input, msgs: ^[dynamic]FV_Msg, field, ok: Widget_ID) {
		widget_store_begin_frame(ws, input^)
		ctx := Ctx(FV_Msg){theme = th, labels = lb, widgets = ws, input = input, msgs = msgs}
		content := col(
			text_input(&ctx, "name", proc(v: string) -> FV_Msg { return .None }, id = field, width = 120),
			button(&ctx, "OK", FV_Msg.Click, id = ok),
		)
		_ = dialog(&ctx, true, content, proc() -> FV_Msg { return .Dismiss }, on_confirm = proc() -> FV_Msg { return .Confirm })
		input^ = {}
	}
	// Open: the first frame never confirms (the Enter that opened it)
	input.keys_pressed = {.Enter}
	frame(&ws, &th, &lb, &input, &msgs, field, ok)
	testing.expect_value(t, len(msgs), 0)
	// A text field focused: Enter confirms
	ws.focused_id = field
	input.keys_pressed = {.Enter}
	frame(&ws, &th, &lb, &input, &msgs, field, ok)
	testing.expect(t, len(msgs) == 1 && msgs[0] == .Confirm, "Enter in a field confirms")
	// A button focused: Enter is the button's click, not a confirm too
	clear(&msgs)
	ws.focused_id = ok
	input.keys_pressed = {.Enter}
	frame(&ws, &th, &lb, &input, &msgs, field, ok)
	testing.expect(t, len(msgs) == 1 && msgs[0] == .Click, "Enter on a button clicks it only")
	// Focus left outside the card (the button that opened it): Enter confirms
	clear(&msgs)
	outside := hash_id("fv-outside")
	ws.states[outside] = Widget_State{kind = .Button, last_rect = {x = 900, y = 900, w = 40, h = 20}, last_frame = ws.frame}
	ws.modal_rect = {x = 0, y = 0, w = 400, h = 300}
	ws.focused_id = outside
	input.keys_pressed = {.Enter}
	frame(&ws, &th, &lb, &input, &msgs, field, ok)
	testing.expect(t, len(msgs) == 1 && msgs[0] == .Confirm, "a button outside the card doesn't take Enter")
	// With a modifier: nothing
	clear(&msgs)
	ws.focused_id = field
	input.keys_pressed = {.Enter}
	input.modifiers = {.Shift}
	frame(&ws, &th, &lb, &input, &msgs, field, ok)
	testing.expect_value(t, len(msgs), 0)
	// Escape dismisses
	input.keys_pressed = {.Escape}
	frame(&ws, &th, &lb, &input, &msgs, field, ok)
	testing.expect(t, len(msgs) == 1 && msgs[0] == .Dismiss, "Escape dismisses")
}

// A dialog's Tab stays on what the dialog drew: a widget behind the scrim under its card isn't a stop
@(test)
dialog_tab_skips_widgets_behind_the_card :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	behind, inside := hash_id("fv-behind"), hash_id("fv-inside")
	ws.states[behind] = Widget_State{kind = .Button, last_rect = {x = 10, y = 10, w = 40, h = 20}}
	ws.states[inside] = Widget_State{kind = .Button, last_rect = {x = 60, y = 10, w = 40, h = 20}, last_overlay_frame = ws.frame}
	append(&ws.focusables, Focusable_Entry{id = behind}, Focusable_Entry{id = inside})
	ws.modal_rect = {x = 0, y = 0, w = 200, h = 100}
	input: Input
	input.keys_pressed = {.Tab}
	widget_store_begin_frame(&ws, input)
	testing.expect_value(t, ws.focused_id, inside)
}
