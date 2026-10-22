package skald

import "core:fmt"
import "core:strings"
import vk "vendor:vulkan"

// Vulkan_Handles is what another renderer needs to draw on Skald's own GPU device:
// its instance, physical and logical device, and the queue family (and queue) Skald
// submits to. See renderer_vulkan_handles and image_create_target.
Vulkan_Handles :: struct {
	instance:        vk.Instance,
	physical_device: vk.PhysicalDevice,
	device:          vk.Device,
	// The graphics + present queue family Skald uses, and its queue 0 (Skald's queue)
	queue_family:    u32,
	queue:           vk.Queue,
}

// renderer_vulkan_handles returns Skald's Vulkan instance, devices and queue, so
// another renderer can share them — SDL's Vulkan renderer, for one, takes them
// through its `SDL_PROP_RENDERER_CREATE_VULKAN_*` properties — and draw into an
// image Skald samples with no copy (image_create_target). Anything made with them
// must be destroyed before Skald's renderer is: use `App.on_shutdown`.
renderer_vulkan_handles :: proc(r: ^Renderer) -> Vulkan_Handles {
	if r == nil { return {} }
	return {r.instance, r.phys_device, r.device, r.queue_family_idx, r.queue}
}

// TARGET_IMAGE_FORMAT is how an image_create_target image is stored: 8-bit BGRA,
// the layout of SDL's `SDL_PIXELFORMAT_BGRA32` (`ARGB8888` on little-endian
// machines), whose Vulkan renderer draws through a UNORM view of it. Skald samples
// it through a `B8G8R8A8_SRGB` view, as it does every other image, so sRGB-encoded
// pixels (what a 2D renderer writes) come out the same as a PNG would.
TARGET_IMAGE_FORMAT :: vk.Format.B8G8R8A8_UNORM

/*
image_create_target makes an image another renderer on Skald's device draws into
and Skald draws from, registered under `key` like any other image: `image(ctx,
key, ...)`, `draw_image`, `draw_image_region`. No pixels are copied: a game engine
or a code editor drawing with SDL's Vulkan renderer (sharing Skald's device:
renderer_vulkan_handles) shows in a Skald widget as it draws.

The image is `width` x `height`, single-level, stored as TARGET_IMAGE_FORMAT
(created MUTABLE_FORMAT, so the producer may view it as UNORM while Skald samples
it as sRGB), usable as a color attachment, a sampled image and a transfer source
and destination, cleared to transparent and left in SHADER_READ_ONLY_OPTIMAL.

The producer's contract:
- It draws on Skald's device, submits to Skald's queue (`Vulkan_Handles.queue`),
  and does so on the thread that runs Skald's frames (between frames: from `view`,
  `update` or a command), so the two never use the queue at once.
- Whenever Skald may draw a frame, the image is back in SHADER_READ_ONLY_OPTIMAL,
  and the producer's writes were made visible to fragment-shader reads by a
  barrier submitted before Skald's frame; and before writing it again the producer
  waits for earlier fragment-shader reads (a barrier whose first scope includes
  them). SDL's Vulkan renderer does both: setting the render target back to the
  window moves the target to SHADER_READ_ONLY_OPTIMAL with such a barrier and
  submits, and making it the target again starts with a barrier from fragment
  shader reads.
- It stops using the image (SDL: destroys its texture) before image_release.

Such images are never evicted from the cache (it would free them under the
producer), and image_update_pixels refuses them. Release one with image_release
(it waits for the device to be idle first). The same key made again replaces the
old image (after a device wait): make the producer let go of the old one first.

Inputs:
- r: The renderer
- key: The name it's drawn by
- width, height: Its size in pixels

Returns:
- The VkImage to hand the producer (SDL: `SDL_PROP_TEXTURE_CREATE_VULKAN_TEXTURE_NUMBER`,
  with `SDL_PROP_TEXTURE_CREATE_VULKAN_LAYOUT_NUMBER` = SHADER_READ_ONLY_OPTIMAL), and
  false when it couldn't be made (no device, a zero size, out of memory)

Example:
	handles := skald.renderer_vulkan_handles(ctx.renderer)
	// ... an SDL Vulkan renderer made with them, then:
	image, ok := skald.image_create_target(ctx.renderer, "scene", 640, 360)
	props := sdl.CreateProperties()
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_VULKAN_TEXTURE_NUMBER, i64(image))
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_VULKAN_LAYOUT_NUMBER, i64(vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL))
	// ... with the format (.BGRA32), access (.TARGET), width and height properties
	texture := sdl.CreateTextureWithProperties(sdlRenderer, props)
*/
image_create_target :: proc(r: ^Renderer, key: string, width, height: u32) -> (image: vk.Image, ok: bool) {
	if r == nil || r.device == nil || width == 0 || height == 0 { return {}, false }

	ici := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO,
		flags = {.MUTABLE_FORMAT},
		imageType = .D2, format = TARGET_IMAGE_FORMAT,
		extent = {width, height, 1}, mipLevels = 1, arrayLayers = 1,
		samples = {._1}, tiling = .OPTIMAL,
		usage = {.SAMPLED, .COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST},
		sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(r.device, &ici, nil, &image); res != .SUCCESS {
		fmt.eprintfln("skald: image_create_target(%s): CreateImage %v", key, res)
		return {}, false
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, image, &req)
	ai := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = req.size,
		memoryTypeIndex = vk_find_mem_type(r, req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	mem: vk.DeviceMemory
	if res := vk.AllocateMemory(r.device, &ai, nil, &mem); res != .SUCCESS {
		fmt.eprintfln("skald: image_create_target(%s): AllocateMemory %v", key, res)
		vk.DestroyImage(r.device, image, nil)
		return {}, false
	}
	vk.BindImageMemory(r.device, image, mem, 0)

	// Cleared (nothing drawn yet shows as transparent, not garbage), then sampleable
	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	cb := vk_begin_one_shot(r)
	to_clear := vk.ImageMemoryBarrier{
		sType = .IMAGE_MEMORY_BARRIER,
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED, newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image, subresourceRange = range,
	}
	vk.CmdPipelineBarrier(cb, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &to_clear)
	clear_color := vk.ClearColorValue{float32 = {0, 0, 0, 0}}
	vk.CmdClearColorImage(cb, image, .TRANSFER_DST_OPTIMAL, &clear_color, 1, &range)
	to_read := vk.ImageMemoryBarrier{
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_READ},
		oldLayout = .TRANSFER_DST_OPTIMAL, newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image, subresourceRange = range,
	}
	vk.CmdPipelineBarrier(cb, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &to_read)
	vk_end_one_shot(r, cb)

	view, dset, vdok := image_make_view_dset(r, image, .B8G8R8A8_SRGB, 1, {})
	if !vdok {
		vk.DestroyImage(r.device, image, nil)
		vk.FreeMemory(r.device, mem, nil)
		return {}, false
	}

	// Register, replacing any prior entry under this key
	if r.images.entries == nil { r.images.entries = make(map[string]^Image_Entry) }
	if _, exists := r.images.entries[key]; exists {
		vk.DeviceWaitIdle(r.device)
		image_cache_drop(r, key)
	}
	r.images.use_counter += 1
	entry := new(Image_Entry)
	entry^ = Image_Entry{
		image = image, mem = mem, view = view, dset = dset,
		width = width, height = height, mip_count = 1,
		external = true, pinned = true, last_use = r.images.use_counter,
	}
	r.images.entries[strings.clone(key)] = entry
	return image, true
}
