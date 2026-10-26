package skald

import "core:log"
import "core:testing"

// `draw_image_region(..., nearest = true)` magnifies with nearest filtering: a 2 x 1
// image (black, white) drawn 32 times bigger stays two flat halves, where linear
// filtering blends a gray ramp across the middle. Rendered off screen (never the
// desktop); needs a display and a Vulkan GPU: skipped (logged) without them.
@(test)
image_nearest_draws_crisp_pixels :: proc(t: ^testing.T) {
	w, ok := window_open("skald nearest test", {64, 32}, {}, {.HIDDEN})
	if !ok { log.info("skipped: no window"); return }
	defer window_destroy(&w)
	r: Renderer
	if !renderer_init(&r, &w) { log.info("skipped: no Vulkan renderer"); return }
	defer renderer_destroy(&r)

	pixels := []u8{0, 0, 0, 255, 255, 255, 255, 255}
	testing.expect(t, image_load_pixels(&r, "nearest-test", 2, 1, pixels, mipmaps = false), "loaded")

	Paint :: struct { nearest: bool }
	render :: proc(t: ^testing.T, r: ^Renderer, nearest: bool) -> (gray: [64]int) {
		p := Paint{nearest}
		v := View_Canvas{user = &p, size = {64, 32}, draw = proc(user: rawptr, painter: Canvas_Painter) {
			p := (^Paint)(user)
			b := painter.bounds
			draw_image_region(painter.r, "nearest-test", {b.x, b.y, 64, 32}, {0, 0, 2, 1}, inset = false, nearest = p.nearest)
		}}
		px, pw, ph, ok := render_view_to_pixels(r, v, 64, 32)
		defer delete(px)
		testing.expect(t, ok && pw == 64 && ph == 32, "rendered")
		if !ok || len(px) < 64 * 32 * 4 { return }
		for x in 0..<64 { gray[x] = int(px[(16 * 64 + x) * 4 + 1]) }
		return
	}
	crisp := render(t, &r, true)
	for x in 0..<64 {
		want := x < 32 ? 0 : 255
		testing.expectf(t, abs(crisp[x] - want) <= 2, "nearest: column %d is %d, want %d", x, crisp[x], want)
	}
	// Linear blends the two texels between their centers (columns 16 to 48)
	smooth := render(t, &r, false)
	testing.expectf(t, smooth[28] > 20 && smooth[28] < 235, "linear: column 28 is %d, a blend", smooth[28])
	// The nearest descriptor set is the entry's second one, made once
	entry := r.images.entries["nearest-test"]
	testing.expect(t, entry != nil && entry.dset_nearest != 0 && entry.dset_nearest != entry.dset, "a nearest set of its own")
}
