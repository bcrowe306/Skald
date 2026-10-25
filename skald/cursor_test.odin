package skald

import "core:testing"

// Pointer shapes: the request rules (plain, soft, top), the built-in
// widgets' hover cursors, and the drawn hand cursors' art. Headless: the
// layout pass is stood in for by stamping last rects.

@(private = "file")
Cur_Msg :: distinct int

@(private = "file")
Cur_Fixture :: struct {
	ws:    Widget_Store,
	th:    Theme,
	lb:    Labels,
	input: Input,
	msgs:  [dynamic]Cur_Msg,
}

@(private = "file")
cur_begin :: proc(f: ^Cur_Fixture) -> Ctx(Cur_Msg) {
	widget_store_begin_frame(&f.ws, f.input)
	return Ctx(Cur_Msg){theme = &f.th, labels = &f.lb, widgets = &f.ws, input = &f.input, msgs = &f.msgs}
}

@(private = "file")
cur_stamp :: proc(f: ^Cur_Fixture, id: Widget_ID, rect: Rect, kind: Widget_Kind) {
	st := f.ws.states[id]
	st.kind       = kind
	st.last_rect  = rect
	st.last_frame = f.ws.frame
	st.last_drawn_frame = f.ws.frame
	f.ws.states[id] = st
}

@(test)
cursor_requests_soft_and_top :: proc(t: ^testing.T) {
	f: Cur_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	defer delete(f.msgs)
	f.th = theme_dark()

	ctx := cur_begin(&f)
	testing.expect_value(t, cursor_current(&ctx), Cursor_Shape.Default)
	cursor_request(&ctx, .Text)
	cursor_request_soft(&ctx, .Pointer) // a container after its text field
	testing.expect_value(t, cursor_current(&ctx), Cursor_Shape.Text)
	cursor_request(&ctx, .Crosshair) // last plain request wins
	testing.expect_value(t, cursor_current(&ctx), Cursor_Shape.Crosshair)
	cursor_request_top(&ctx, .Pointer) // an open menu built early
	cursor_request(&ctx, .Text)
	cursor_request_soft(&ctx, .Move)
	testing.expect_value(t, cursor_current(&ctx), Cursor_Shape.Pointer)

	// The next frame starts over.
	ctx = cur_begin(&f)
	testing.expect_value(t, cursor_current(&ctx), Cursor_Shape.Default)
	cursor_request(&ctx, .Grab)
	testing.expect_value(t, cursor_current(&ctx), Cursor_Shape.Grab)
}

@(test)
cursor_follows_the_built_in_widgets :: proc(t: ^testing.T) {
	f: Cur_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	defer delete(f.msgs)
	f.th = theme_dark()

	btn   := hash_id("cur-button")
	off   := hash_id("cur-disabled")
	field := hash_id("cur-field")
	cur_stamp(&f, btn, {0, 0, 100, 30}, .Button)
	cur_stamp(&f, off, {0, 40, 100, 30}, .Button)
	cur_stamp(&f, field, {0, 80, 100, 30}, .Text_Input)

	check :: proc(t: ^testing.T, f: ^Cur_Fixture, at: [2]f32, want: Cursor_Shape, loc := #caller_location) {
		f.input.mouse_pos = at
		ctx := cur_begin(f)
		_ = button(&ctx, "Go", Cur_Msg(1), id = hash_id("cur-button"))
		_ = button(&ctx, "Off", Cur_Msg(2), id = hash_id("cur-disabled"), disabled = true)
		_ = text_input(&ctx, "abc", proc(s: string) -> Cur_Msg { return 3 }, id = hash_id("cur-field"))
		testing.expect_value(t, cursor_current(&ctx), want, loc = loc)
		for id in ([]Widget_ID{hash_id("cur-button"), hash_id("cur-disabled"), hash_id("cur-field")}) {
			st := f.ws.states[id]
			st.last_frame = f.ws.frame
			st.last_drawn_frame = f.ws.frame
			f.ws.states[id] = st
		}
	}
	check(t, &f, {50, 15}, .Pointer)
	check(t, &f, {50, 55}, .Not_Allowed)
	check(t, &f, {50, 95}, .Text)
	check(t, &f, {50, 200}, .Default)
}

@(test)
cursor_hand_art_is_well_formed :: proc(t: ^testing.T) {
	for shape in Cursor_Shape {
		art, drawn := cursor_bitmap(shape)
		testing.expect_value(t, drawn, shape == .Grab || shape == .Grabbing)
		if !drawn { continue }
		inked := 0
		for row in art {
			testing.expect_value(t, len(row), 16)
			for c in row {
				testing.expectf(t, c == ' ' || c == '#' || c == '.', "%v: bad character %q", shape, c)
				if c != ' ' { inked += 1 }
			}
		}
		testing.expect(t, inked > 60, "a hand has some ink")
	}
}
