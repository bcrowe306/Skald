package skald

// The measure_text cache (text.odin's Text.measure_cache): hits by content
// whatever the string's address, misses on any argument that changes the
// result, cleared by font changes, swept when unused.

import "core:strings"
import "core:testing"

@(test)
measure_cache_hits_by_content :: proc(t: ^testing.T) {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		delete(r.text.measure_cache)
		free(r.cur)
		free(r)
	}
	if r.text.runa_state == nil { return }

	w1, h1 := measure_text(r, "Inspector: Position X", 14)
	testing.expect_value(t, len(r.text.measure_cache), 1)
	uw, uh := measure_text_uncached(r, "Inspector: Position X", 14, 0)
	testing.expect_value(t, w1, uw)
	testing.expect_value(t, h1, uh)

	// The same text at another address (views rebuild their strings each frame) is a hit
	copy := strings.clone("Inspector: Position X", context.temp_allocator)
	w2, h2 := measure_text(r, copy, 14)
	testing.expect_value(t, len(r.text.measure_cache), 1)
	testing.expect_value(t, w2, w1)
	testing.expect_value(t, h2, h1)

	// Another size, font or scale is another measurement
	w3, _ := measure_text(r, "Inspector: Position X", 20)
	testing.expect(t, w3 > w1, "bigger text is wider")
	testing.expect_value(t, len(r.text.measure_cache), 2)
	measure_text(r, "Inspector: Position X", 14, font_bold(r))
	testing.expect_value(t, len(r.text.measure_cache), 3)
	r.scale = 2
	ws, _ := measure_text(r, "Inspector: Position X", 14)
	testing.expect_value(t, len(r.text.measure_cache), 4)
	us, _ := measure_text_uncached(r, "Inspector: Position X", 14, 0)
	testing.expect_value(t, ws, us)
	r.scale = 1

	// Unused entries go at the next sweep; used ones stay
	for _ in 0 ..< MEASURE_CACHE_KEEP_FRAMES - 1 { text_measure_cache_tick(&r.text) }
	measure_text(r, "Inspector: Position X", 14)
	text_measure_cache_tick(&r.text)
	testing.expect_value(t, len(r.text.measure_cache), 1)

	// A font change clears it: a fallback can change what a string measures
	font_add_fallback(r, font_default(r), font_use_default_emoji(r))
	testing.expect_value(t, len(r.text.measure_cache), 0)
}

// draw_text's laid-out glyphs (Text_Runa.run_cache): a string drawn again
// draws the same glyphs from the cache; font changes clear it.
@(test)
draw_cache_draws_the_same_glyphs :: proc(t: ^testing.T) {
	r := new(Renderer)
	r.cur = new(Window_Target)
	r.scale = 1
	r.text.atlas_w = ATLAS_SIZE
	r.text.atlas_h = ATLAS_SIZE
	text_init_runa(&r.text, r)
	defer {
		if r.text.runa_state != nil { text_runa_free(r.text.runa_state) }
		delete(r.text.measure_cache)
		delete(r.batch.vertices)
		delete(r.batch.indices)
		delete(r.batch.ranges)
		delete(r.batch.clip_stack)
		free(r.cur)
		free(r)
	}
	if r.text.runa_state == nil { return }
	rs := r.text.runa_state

	draw_text(r, "Position X: 120", 10, 20, Color{1, 1, 1, 1}, 14)
	testing.expect_value(t, len(rs.run_cache), 1)
	first := len(r.batch.vertices)
	testing.expect(t, first > 0, "the text drew quads")
	firstVerts := make([]Vertex, first, context.temp_allocator)
	copy(firstVerts, r.batch.vertices[:])
	clear(&r.batch.vertices)
	clear(&r.batch.indices)

	// From the cache (another address, the same text): the same quads
	again := strings.clone("Position X: 120", context.temp_allocator)
	draw_text(r, again, 10, 20, Color{1, 1, 1, 1}, 14)
	testing.expect_value(t, len(rs.run_cache), 1)
	testing.expect_value(t, len(r.batch.vertices), first)
	if len(r.batch.vertices) == first {
		for v, i in r.batch.vertices do testing.expect_value(t, v, firstVerts[i])
	}

	// Another size is another run; a font change clears them
	draw_text(r, "Position X: 120", 10, 20, Color{1, 1, 1, 1}, 20)
	testing.expect_value(t, len(rs.run_cache), 2)
	font_add_fallback(r, font_default(r), font_use_default_emoji(r))
	testing.expect_value(t, len(rs.run_cache), 0)
}
