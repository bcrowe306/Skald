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

// stack_render lays a stack's children out from the sizes view_size kept when
// the parent measured it (Renderer.stack_size_cache): the same rects as
// measuring them again.
@(test)
stacks_lay_out_alike_from_kept_sizes :: proc(t: ^testing.T) {
	layout_rects :: proc(cache: bool) -> [6]Rect {
		ws: Widget_Store
		widget_store_init(&ws)
		defer widget_store_destroy(&ws)
		ws.frame = 1
		r := new(Renderer)
		r.cur = new(Window_Target)
		r.scale = 1
		r.fb_size = {400, 300}
		r.alpha_multiplier = 1
		r.widgets = &ws
		defer {
			batch_destroy(&r.batch)
			free(r.cur)
			free(r)
		}
		r.frame_valid = cache
		if cache { r.stack_size_cache = make(map[Stack_Size_Key]Stack_Size_Entry, allocator = context.temp_allocator) }

		zone_of :: proc(id: int, size: [2]f32) -> View {
			return View_Zone{id = Widget_ID(2000 + id), child = new_clone(rect(size, {1, 1, 1, 1}), context.temp_allocator)}
		}
		flexed := new_clone(zone_of(1, {30, 10}), context.temp_allocator)
		column := []View{zone_of(0, {50, 20}), View_Flex{weight = 1, child = flexed}, zone_of(2, {70, 15})}
		inner := []View{zone_of(3, {40, 40}), View(View_Stack{direction = .Column, spacing = 4, padding = 3, children = column})}
		row := []View{View(View_Stack{direction = .Row, spacing = 6, cross_align = .Center, children = inner}), zone_of(4, {20, 90}), zone_of(5, {10, 10})}
		root := View(View_Stack{direction = .Row, spacing = 2, padding = 5, children = row})
		batch_reset(&r.batch)
		render_view(r, root, {0, 0}, {400, 300})
		out: [6]Rect
		for i in 0 ..< 6 { out[i] = ws.states[Widget_ID(2000 + i)].last_rect }
		return out
	}
	measured := layout_rects(false)
	kept := layout_rects(true)
	for i in 0 ..< 6 {
		testing.expectf(t, measured[i] == kept[i], "zone %d: %v measured, %v from kept sizes", i, measured[i], kept[i])
		testing.expectf(t, measured[i].w > 0, "zone %d laid out", i)
	}
}
