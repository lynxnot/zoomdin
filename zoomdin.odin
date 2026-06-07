package zoomdin

import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import wl "pkg/wayland"
import "pkg/wayland/xdg"

global_context: runtime.Context

zooWindow: struct {
	display:    ^wl.display,
	compositor: ^wl.compositor,
	surface:    ^wl.surface,
	seat:       ^wl.seat,
	shm:        ^wl.shm,
	wm_base:    ^xdg.wm_base,
	data:       [^]u32,
	pool:       ^wl.shm_pool,
	buffer:     ^wl.buffer,
	curWidth:   int,
	curHeight:  int,
	quit:       bool,
	outputs:    [dynamic]^wl.output,
}

////////////////////////////////////////////////////////////////////////////////
// registry
registry_global :: proc "c" (
	data: rawptr,
	registry: ^wl.registry,
	name: uint,
	interface: cstring,
	version: uint,
) {

	context = global_context
	//fmt.println("registry_global: name=", name, " interface=", interface, " version=", version)
	fmt.println(interface)
	switch interface {
	case wl.compositor_interface.name:
		zooWindow.compositor = cast(^wl.compositor)wl.registry_bind(
			registry,
			name,
			&wl.compositor_interface,
			5,
		)
	case wl.shm_interface.name:
		zooWindow.shm = cast(^wl.shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
	case xdg.wm_base_interface.name:
		zooWindow.wm_base = cast(^xdg.wm_base)wl.registry_bind(
			registry,
			name,
			&xdg.wm_base_interface,
			7,
		)
	case wl.seat_interface.name:
		zooWindow.seat = cast(^wl.seat)wl.registry_bind(registry, name, &wl.seat_interface, 9)
	case wl.output_interface.name:
		append(
			&zooWindow.outputs,
			cast(^wl.output)wl.registry_bind(registry, name, &wl.output_interface, 4),
		)
	}

}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {
}

registry_listener := wl.registry_listener {
	global        = registry_global,
	global_remove = registry_global_remove,
}

////////////////////////////////////////////////////////////////////////////////
// wm_base
wm_base_ping :: proc "c" (data: rawptr, wm_base: ^xdg.wm_base, serial: uint) {
	xdg.wm_base_pong(wm_base, serial)
}

wm_base_listener := xdg.wm_base_listener {
	ping = wm_base_ping,
}

////////////////////////////////////////////////////////////////////////////////
// buffer management
create_shm_pool :: proc() {
	context = global_context
	width := 2560
	height := 1440
	// 4 bytes per pixel (ARGB)
	stride := width * 4
	size := stride * height

	// create shared memory for the framebuffer
	// posix.open -> posix.unlink -> posix.ftruncate -> mmap
	// creates an anonymous shared memory segment, held by the kernel until something
	// references the file descriptor
	name := fmt.caprintf("/wl_zoo_%v", cast(uintptr)zooWindow.display) // randomish name
	fd := posix.shm_open(name, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if fd == -1 {
		fmt.println("Error: could not create shared memory: ", posix.strerror(posix.errno()))
		return
	}
	posix.shm_unlink(name)
	res := posix.ftruncate(fd, auto_cast size)
	if res == .FAIL {
		fmt.println("Error: could not resize shared memory: ", posix.strerror(posix.errno()))
		posix.close(fd)
		return
	}
	raw_data, err := linux.mmap(
		auto_cast 0,
		uint(size),
		{.READ, .WRITE},
		{.SHARED},
		auto_cast fd,
		0,
	)
	zooWindow.data = cast([^]u32)raw_data
	if err != .NONE {
		fmt.println("Error: could not mmap: ", err)
		posix.close(fd)
		return
	}

	zooWindow.pool = wl.shm_create_pool(zooWindow.shm, auto_cast fd, size)
	posix.close(fd)
}

sync_geometry :: proc() {
	if zooWindow.curHeight == 0 || zooWindow.curWidth == 0 {
		return
	}

	old_buffer := zooWindow.buffer

	stride := zooWindow.curWidth * 4

	// create a new buffer
	new_buffer := wl.shm_pool_create_buffer(
		zooWindow.pool,
		0,
		zooWindow.curWidth,
		zooWindow.curHeight,
		stride,
		.argb8888,
	)

	// draw the buffer
	draw_buffer()

	// update state and commit new buffer
	zooWindow.buffer = new_buffer
	wl.surface_attach(zooWindow.surface, zooWindow.buffer, 0, 0)
	wl.surface_commit(zooWindow.surface)

	// free old buffer
	if old_buffer != nil {
		wl.buffer_destroy(old_buffer)
	}

}

draw_buffer :: proc() {
	// draw checkerboard
	for y in 0 ..< zooWindow.curHeight {
		for x in 0 ..< zooWindow.curWidth {
			index := y * zooWindow.curWidth + x
			if (x + y / 16 * 16) % 32 < 16 do zooWindow.data[index] = 0xFFEE00EE
			else do zooWindow.data[index] = 0x33333333
		}
	}
}

////////////////////////////////////////////////////////////////////////////////
// surface
surface_configure :: proc "c" (data: rawptr, surface: ^xdg.surface, serial: uint) {
	context = global_context
	xdg.surface_ack_configure(surface, serial)
	sync_geometry()
}

surface_listener := xdg.surface_listener {
	configure = surface_configure,
}

////////////////////////////////////////////////////////////////////////////////
// toplevel
toplevel_configure :: proc "c" (
	data: rawptr,
	toplevel: ^xdg.toplevel,
	width: int,
	height: int,
	states: wl.array,
) {
	context = global_context
	if width == 0 || height == 0 {
		zooWindow.curWidth = 1280
		zooWindow.curHeight = 720
	} else {
		zooWindow.curWidth = width
		zooWindow.curHeight = height
	}
}

toplevel_close :: proc "c" (data: rawptr, toplevel: ^xdg.toplevel) {
	context = global_context
	zooWindow.quit = true
}

toplevel_configure_bounds :: proc "c" (
	data: rawptr,
	toplevel: ^xdg.toplevel,
	width: int,
	height: int,
) {
	context = global_context
	zooWindow.curWidth = width
	zooWindow.curHeight = height
}

toplevel_wm_capabilities :: proc "c" (
	data: rawptr,
	toplevel: ^xdg.toplevel,
	capabilities: wl.array,
) {
	context = global_context
}

toplevel_listener := xdg.toplevel_listener {
	configure        = toplevel_configure,
	close            = toplevel_close,
	configure_bounds = toplevel_configure_bounds,
	wm_capabilities  = toplevel_wm_capabilities,
}

main :: proc() {
	global_context = context

	// --- Startup Phase ---
	zooWindow.display = wl.display_connect(nil)
	if zooWindow.display == nil {
		fmt.println("Failed to connect to a wayland display")
		return
	}

	registry := wl.display_get_registry(zooWindow.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(zooWindow.display)

	// --- Initialize Pool and Setup Surfaces  ---
	create_shm_pool()
	zooWindow.surface = wl.compositor_create_surface(zooWindow.compositor)

	xdg.wm_base_add_listener(zooWindow.wm_base, &wm_base_listener, nil)
	xdg_surface := xdg.wm_base_get_xdg_surface(zooWindow.wm_base, zooWindow.surface)
	xdg.surface_add_listener(xdg_surface, &surface_listener, nil)

	// --- Setup Toplevel ---
	toplevel := xdg.surface_get_toplevel(xdg_surface)
	xdg.toplevel_set_title(toplevel, "Zoomdin")
	xdg.toplevel_add_listener(toplevel, &toplevel_listener, nil)

	wl.surface_commit(zooWindow.surface)
	wl.display_roundtrip(zooWindow.display)

	// --- Main Loop ---
	zooWindow.quit = false
	for wl.display_dispatch(zooWindow.display) != 0 {
		if zooWindow.quit {
			break
		}
		// keep cpu cool
		time.sleep(4 * time.Millisecond)
	}

	// --- Cleanup ---
	if zooWindow.surface != nil do wl.surface_destroy(zooWindow.surface)
	if zooWindow.pool != nil do wl.shm_pool_destroy(zooWindow.pool)
	wl.registry_destroy(registry)
}
