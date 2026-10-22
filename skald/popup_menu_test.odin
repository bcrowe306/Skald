package skald

import "core:log"
import "core:testing"

// A popup_menu the app opened: a release on a command sends it and closes; a submenu opens on
// hover and its items send theirs; disabled rows and separators send nothing; the keys walk it;
// a press outside closes it without choosing. Needs a renderer to measure text (a hidden
// window): skipped without a display or GPU.

@(private = "file")
PM_Msg :: distinct int

@(private = "file")
PM_CLOSED :: PM_Msg(-1)

@(test)
popup_menu_chooses_and_closes :: proc(t: ^testing.T) {
	w, ok := window_open("skald popup menu test", {800, 600}, {}, {.HIDDEN})
	if !ok { log.info("skipped: no window"); return }
	defer window_destroy(&w)
	r: Renderer
	if !renderer_init(&r, &w) { log.info("skipped: no Vulkan renderer"); return }
	defer renderer_destroy(&r)
	r.fb_size = {800, 600}

	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	th := theme_dark()
	lb := labels_en()
	msgs: [dynamic]PM_Msg
	defer delete(msgs)
	input: Input
	id := hash_id("pm")
	items := []Menu_Item(PM_Msg){
		{label = "Cut", shortcut = {.X, {.Ctrl}}, msg = 1},
		{label = "Disabled", msg = 2, disabled = true},
		{separator = true},
		{label = "Align", submenu = []Menu_Item(PM_Msg){
			{label = "Left", msg = 10},
			{label = "Right", msg = 11},
		}},
		{label = "Snap", msg = 3, checked = true},
	}
	at := [2]f32{100, 100}
	frame :: proc(ws: ^Widget_Store, r: ^Renderer, th: ^Theme, lb: ^Labels, input: ^Input, msgs: ^[dynamic]PM_Msg, id: Widget_ID, items: []Menu_Item(PM_Msg), at: [2]f32) {
		widget_store_begin_frame(ws, input^)
		ctx := Ctx(PM_Msg){theme = th, labels = lb, widgets = ws, input = input, msgs = msgs, renderer = r}
		_ = popup_menu(&ctx, items, at, PM_CLOSED, id = id)
		input^ = {}
	}
	ctx := Ctx(PM_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = &r}
	center :: proc(r: Rect) -> [2]f32 { return {r.x + r.w / 2, r.y + r.h / 2} }
	row :: proc(ctx: ^Ctx(PM_Msg), items: []Menu_Item(PM_Msg), at: [2]f32, i: int, sub := -1) -> [2]f32 {
		r := popup_menu_row_rect(ctx, items, at, i, sub)
		return {r.x + r.w / 2, r.y + r.h / 2}
	}

	// Open, then release on Cut: Cut, then closed
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	testing.expect_value(t, len(msgs), 0)
	input.mouse_pos = row(&ctx, items, at, 0)
	input.mouse_released[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	testing.expect(t, len(msgs) == 2 && msgs[0] == 1 && msgs[1] == PM_CLOSED, "Cut, then closed")
	clear(&msgs)

	// A disabled row and a separator send nothing
	input.mouse_pos = row(&ctx, items, at, 1)
	input.mouse_released[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	input.mouse_pos = row(&ctx, items, at, 2)
	input.mouse_released[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	testing.expect_value(t, len(msgs), 0)

	// Hovering Align opens its submenu; Right in it sends 11
	input.mouse_pos = row(&ctx, items, at, 3)
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	testing.expect_value(t, ws.states[id].selection_anchor, 4)
	input.mouse_pos = row(&ctx, items, at, 1, sub = 3)
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	testing.expect_value(t, ws.states[id].selection_anchor, 4) // still open over the submenu
	input.mouse_pos = row(&ctx, items, at, 1, sub = 3)
	input.mouse_released[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at)
	testing.expect(t, len(msgs) == 2 && msgs[0] == 11 && msgs[1] == PM_CLOSED, "Right, then closed")
	clear(&msgs)

	// Keys, opened somewhere else (fresh): Down skips the disabled row and the separator
	at2 := [2]f32{300, 200}
	input.mouse_pos = {700, 550}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	input.keys_pressed = {.Down}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	testing.expect_value(t, ws.states[id].cursor_pos, 1) // Cut
	input.keys_pressed = {.Down}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	testing.expect_value(t, ws.states[id].cursor_pos, 4) // Align
	input.keys_pressed = {.Right}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	testing.expect_value(t, ws.states[id].selection_anchor, 4)
	input.keys_pressed = {.Enter}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	testing.expect(t, len(msgs) == 2 && msgs[0] == 10 && msgs[1] == PM_CLOSED, "Left by keys")
	clear(&msgs)

	// A press outside closes it, choosing nothing; Escape too
	input.mouse_pos = {5, 5}
	input.mouse_pressed[.Right] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	testing.expect(t, len(msgs) == 1 && msgs[0] == PM_CLOSED, "closed by a press outside")
	clear(&msgs)
	input.keys_pressed = {.Escape}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, items, at2)
	testing.expect(t, len(msgs) == 1 && msgs[0] == PM_CLOSED, "closed by Escape")
}
