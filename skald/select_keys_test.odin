package skald

import "core:testing"

// A focused, closed select steps through its options with Up / Down, as native dropdowns do,
// and stops at the ends; open, the keys are the list's.

@(private = "file")
SK_Msg :: distinct int

@(test)
select_steps_with_up_and_down_while_closed :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	msgs: [dynamic]SK_Msg
	defer delete(msgs)
	input: Input

	id := hash_id("sk-select")
	options := []string{"Alpha", "Beta", "Gamma"}
	option_msgs := []SK_Msg{0, 1, 2}
	frame :: proc(ws: ^Widget_Store, th: ^Theme, lb: ^Labels, input: ^Input, msgs: ^[dynamic]SK_Msg, id: Widget_ID, value: string, options: []string, option_msgs: []SK_Msg) {
		widget_store_begin_frame(ws, input^)
		ctx := Ctx(SK_Msg){theme = th, labels = lb, widgets = ws, input = input, msgs = msgs}
		_ = _select_impl(&ctx, value, options, option_msgs, id = id, width = 160)
		input^ = {}
	}
	// A first frame registers it; then it takes focus
	frame(&ws, &th, &lb, &input, &msgs, id, "Beta", options, option_msgs)
	ws.focused_id = id

	input.keys_pressed = {.Down}
	frame(&ws, &th, &lb, &input, &msgs, id, "Beta", options, option_msgs)
	testing.expect(t, len(msgs) == 1 && msgs[0] == 2, "Down picks the next option")
	input.keys_pressed = {.Up}
	frame(&ws, &th, &lb, &input, &msgs, id, "Beta", options, option_msgs)
	testing.expect(t, len(msgs) == 2 && msgs[1] == 0, "Up picks the previous one")
	// At the end: nothing to step to
	input.keys_pressed = {.Down}
	frame(&ws, &th, &lb, &input, &msgs, id, "Gamma", options, option_msgs)
	testing.expect_value(t, len(msgs), 2)
	// Open (Enter), the keys don't change the value
	input.keys_pressed = {.Enter}
	frame(&ws, &th, &lb, &input, &msgs, id, "Alpha", options, option_msgs)
	testing.expect(t, ws.states[id].open, "Enter opens it")
	input.keys_pressed = {.Down}
	frame(&ws, &th, &lb, &input, &msgs, id, "Alpha", options, option_msgs)
	testing.expect_value(t, len(msgs), 2)
}
