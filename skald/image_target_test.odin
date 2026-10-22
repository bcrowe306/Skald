package skald

import "core:log"
import "core:testing"
import "vendor:sdl3"
import vk "vendor:vulkan"

// An SDL Vulkan renderer on Skald's device draws into an image_create_target image;
// Skald draws that image (off screen, never the desktop) with SDL's pixels in it.
// Needs a display and a Vulkan GPU: skipped (logged) without them.
@(test)
image_target_shows_what_sdl_draws :: proc(t: ^testing.T) {
	w, ok := window_open("skald image_target test", {64, 64}, {}, {.HIDDEN})
	if !ok { log.info("skipped: no window"); return }
	defer window_destroy(&w)
	r: Renderer
	if !renderer_init(&r, &w) { log.info("skipped: no Vulkan renderer"); return }
	defer renderer_destroy(&r)

	// SDL's Vulkan renderer on Skald's device, on a hidden window of its own
	h := renderer_vulkan_handles(&r)
	testing.expect(t, h.device != nil && h.queue != nil, "handles")
	sdlWindow := sdl3.CreateWindow("skald image_target producer", 16, 16, {.HIDDEN, .VULKAN})
	if sdlWindow == nil { log.info("skipped: no SDL window"); return }
	defer sdl3.DestroyWindow(sdlWindow)
	props := sdl3.CreateProperties()
	defer sdl3.DestroyProperties(props)
	sdl3.SetStringProperty(props, sdl3.PROP_RENDERER_CREATE_NAME_STRING, "vulkan")
	sdl3.SetPointerProperty(props, sdl3.PROP_RENDERER_CREATE_WINDOW_POINTER, sdlWindow)
	sdl3.SetPointerProperty(props, sdl3.PROP_RENDERER_CREATE_VULKAN_INSTANCE_POINTER, h.instance)
	sdl3.SetPointerProperty(props, sdl3.PROP_RENDERER_CREATE_VULKAN_PHYSICAL_DEVICE_POINTER, h.physical_device)
	sdl3.SetPointerProperty(props, sdl3.PROP_RENDERER_CREATE_VULKAN_DEVICE_POINTER, h.device)
	sdl3.SetNumberProperty(props, sdl3.PROP_RENDERER_CREATE_VULKAN_GRAPHICS_QUEUE_FAMILY_INDEX_NUMBER, i64(h.queue_family))
	sdl3.SetNumberProperty(props, sdl3.PROP_RENDERER_CREATE_VULKAN_PRESENT_QUEUE_FAMILY_INDEX_NUMBER, i64(h.queue_family))
	producer := sdl3.CreateRendererWithProperties(props)
	if producer == nil { log.infof("skipped: no SDL Vulkan renderer (%s)", sdl3.GetError()); return }
	defer sdl3.DestroyRenderer(producer)

	// The target, wrapped as an SDL render target
	image, made := image_create_target(&r, "image-target-test", 64, 32)
	testing.expect(t, made, "target made")
	if !made do return
	tprops := sdl3.CreateProperties()
	defer sdl3.DestroyProperties(tprops)
	sdl3.SetNumberProperty(tprops, sdl3.PROP_TEXTURE_CREATE_FORMAT_NUMBER, i64(sdl3.PixelFormat.BGRA32))
	sdl3.SetNumberProperty(tprops, sdl3.PROP_TEXTURE_CREATE_ACCESS_NUMBER, i64(sdl3.TextureAccess.TARGET))
	sdl3.SetNumberProperty(tprops, sdl3.PROP_TEXTURE_CREATE_WIDTH_NUMBER, 64)
	sdl3.SetNumberProperty(tprops, sdl3.PROP_TEXTURE_CREATE_HEIGHT_NUMBER, 32)
	sdl3.SetNumberProperty(tprops, sdl3.PROP_TEXTURE_CREATE_VULKAN_TEXTURE_NUMBER, i64(uintptr(image)))
	sdl3.SetNumberProperty(tprops, sdl3.PROP_TEXTURE_CREATE_VULKAN_LAYOUT_NUMBER, i64(vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL))
	texture := sdl3.CreateTextureWithProperties(producer, tprops)
	testing.expectf(t, texture != nil, "texture: %s", sdl3.GetError())
	if texture == nil do return

	// Draw twice (the second over what Skald sampled): red with a blue right half
	pixelsAfter := proc(t: ^testing.T, r: ^Renderer) -> []u8 {
		px, pw, ph, ok := render_view_to_pixels(r, View_Image{path = "image-target-test", size = {64, 32}, fit = .Fill, tint = {1, 1, 1, 1}}, 64, 32)
		testing.expect(t, ok && pw == 64 && ph == 32, "skald rendered it")
		return px
	}
	for green in ([]u8{40, 200}) {
		sdl3.SetRenderTarget(producer, texture)
		sdl3.SetRenderDrawColor(producer, 220, green, 30, 255)
		sdl3.RenderClear(producer)
		sdl3.SetRenderDrawColor(producer, 30, 60, 220, 255)
		half := sdl3.FRect{32, 0, 32, 32}
		sdl3.RenderFillRect(producer, &half)
		sdl3.SetRenderTarget(producer, nil)

		px := pixelsAfter(t, &r)
		defer delete(px)
		if len(px) < 64 * 32 * 4 do continue
		// B, G, R, A rows of 64
		at :: proc(px: []u8, x, y: int) -> [3]u8 { p := px[(y * 64 + x) * 4:]; return {p[2], p[1], p[0]} }
		near :: proc(a, b: [3]u8) -> bool { for i in 0..<3 do if abs(int(a[i]) - int(b[i])) > 2 do return false; return true }
		testing.expectf(t, near(at(px, 8, 16), {220, green, 30}), "left: %v", at(px, 8, 16))
		testing.expectf(t, near(at(px, 56, 16), {30, 60, 220}), "right: %v", at(px, 56, 16))
	}

	// The producer lets go first, then Skald releases it
	sdl3.DestroyTexture(texture)
	testing.expect(t, image_release(&r, "image-target-test"), "released")
}
