package skald

import "core:log"
import "core:testing"

// A menu_bar item with a submenu: hovering its row opens the submenu beside the dropdown, clicking
// the row sends nothing, choosing a submenu item sends its msg and closes everything, hovering
// another command closes the submenu. Needs a renderer to measure text (a hidden window):
// skipped without a display or GPU.

@(private = "file")
SM_Msg :: distinct int

@(test)
menu_bar_submenus_open_on_hover_and_send_their_items :: proc(t: ^testing.T) {
	w, ok := window_open("skald submenu test", {800, 600}, {}, {.HIDDEN})
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
	msgs: [dynamic]SM_Msg
	defer delete(msgs)
	input: Input
	id := hash_id("sm-bar")
	entries := []Menu_Entry(SM_Msg){
		{"File", []Menu_Item(SM_Msg){
			{label = "New", msg = 1},
			{label = "Open Recent", submenu = []Menu_Item(SM_Msg){
				{label = "Alpha", msg = 10},
				{label = "Beta", msg = 11},
			}},
			{separator = true},
			{label = "Quit", msg = 2},
		}},
	}
	frame :: proc(ws: ^Widget_Store, r: ^Renderer, th: ^Theme, lb: ^Labels, input: ^Input, msgs: ^[dynamic]SM_Msg, id: Widget_ID, entries: []Menu_Entry(SM_Msg)) {
		widget_store_begin_frame(ws, input^)
		ctx := Ctx(SM_Msg){theme = th, labels = lb, widgets = ws, input = input, msgs = msgs, renderer = r}
		_ = menu_bar(&ctx, entries, id = id)
		input^ = {}
	}
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	// The bar's rect (the renderer stamps it when drawn)
	st := ws.states[id]
	st.last_rect = {0, 0, 400, 30}
	ws.states[id] = st

	// Open File
	input.mouse_pos = {10, 10}
	input.mouse_pressed[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect_value(t, ws.states[id].cursor_pos, 1)

	// Where the dropdown and its rows are (as menu_bar lays them out)
	ctx := Ctx(SM_Msg){theme = &th, labels = &lb, widgets = &ws, input = &input, msgs = &msgs, renderer = &r}
	m := menu_metrics(&ctx)
	items := entries[0].items
	drop := menu_measure(&ctx, m, items)
	trig_h := th.font.size_md + 2*th.spacing.sm + 4
	dropdown := Rect{0, trig_h, drop.w, drop.h}
	center :: proc(r: Rect) -> [2]f32 { return {r.x + r.w / 2, r.y + r.h / 2} }

	// Hovering "Open Recent" opens its submenu; a click on the row sends nothing
	recent := menu_row_rect(m, items, dropdown, 1)
	input.mouse_pos = center(recent)
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect_value(t, ws.states[id].selection_anchor, 2)
	input.mouse_pos = center(recent)
	input.mouse_released[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect_value(t, len(msgs), 0)
	testing.expect_value(t, ws.states[id].cursor_pos, 1)

	// The submenu is beside the dropdown, its first row level with the parent row
	sub := menu_measure(&ctx, m, items[1].submenu)
	sub_rect := Rect{dropdown.x + dropdown.w - m.border, recent.y - m.pad - m.border, sub.w, sub.h}
	beta := menu_row_rect(m, items[1].submenu, sub_rect, 1)
	input.mouse_pos = center(beta)
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect_value(t, ws.states[id].selection_anchor, 2) // still open over the submenu
	input.mouse_pos = center(beta)
	input.mouse_released[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect(t, len(msgs) == 1 && msgs[0] == 11, "Beta sent")
	testing.expect_value(t, ws.states[id].cursor_pos, 0)
	testing.expect_value(t, ws.states[id].selection_anchor, 0)

	// Open again: hovering another command closes the submenu
	input.mouse_pos = {10, 10}
	input.mouse_pressed[.Left] = true
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	input.mouse_pos = center(recent)
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect_value(t, ws.states[id].selection_anchor, 2)
	input.mouse_pos = center(menu_row_rect(m, items, dropdown, 0))
	frame(&ws, &r, &th, &lb, &input, &msgs, id, entries)
	testing.expect_value(t, ws.states[id].selection_anchor, 0)
	testing.expect_value(t, ws.states[id].cursor_pos, 1)
}
