package skald

// Culling (layout.odin's stack_render): children of a stack wholly outside the active clip are
// laid out with drawing suppressed, so a long scroll puts only what's in view into the batch,
// while every row's widget still gets its rect (the reveal and hit-test code reads them).

import "core:testing"

@(test)
culled_rows_draw_nothing_but_keep_their_rects :: proc(t: ^testing.T) {
	ws: Widget_Store
	widget_store_init(&ws)
	defer widget_store_destroy(&ws)
	ws.frame = 1
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.fb_size = {200, 200}
	r.alpha_multiplier = 1
	r.widgets = &ws
	defer {
		batch_destroy(&r.batch)
		free(r.cur)
		free(r)
	}

	ROWS :: 200
	ROW_H :: f32(20)
	rows := make([]View, ROWS, context.temp_allocator)
	for i in 0 ..< ROWS {
		child := new_clone(rect({100, ROW_H}, {1, 0, 0, 1}), context.temp_allocator)
		rows[i] = View_Zone{id = Widget_ID(1000 + i), child = child}
	}
	content := new_clone(View(View_Stack{direction = .Column, children = rows}), context.temp_allocator)
	scroll := View(View_Scroll{id = hash_id("cull-scroll"), size = {120, 100}, content = content})

	batch_reset(&r.batch)
	render_view(r, scroll, {0, 0}, {120, 100})
	// The viewport shows 5 rows; the margin (CULL_MARGIN) draws a couple more each side. Each row
	// is one rect: 4 vertices. Without culling all 200 rows (800 vertices) reached the batch
	drawnRows := len(r.batch.vertices) / 4
	testing.expectf(t, drawnRows >= 5 && drawnRows <= 12, "rows drawn: %d of %d", drawnRows, ROWS)
	testing.expect_value(t, r.draw_suppressed, 0)

	// A row far below the viewport was laid out all the same: its rect is where it belongs
	far := ws.states[Widget_ID(1000 + 150)]
	testing.expect_value(t, far.last_rect, Rect{0, 150 * ROW_H, 100, ROW_H})
	testing.expect_value(t, far.last_drawn_frame, ws.frame)
	testing.expect(t, widget_drawn_last_frame(&ws, far), "laid out counts as drawn")
}
