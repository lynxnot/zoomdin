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
	pointer:    ^wl.pointer,
	keyboard:   ^wl.keyboard,
	shm:        ^wl.shm,
	wm_base:    ^xdg.wm_base,
	data:       [^]u32,
	pool:       ^wl.shm_pool,
	buffer:     ^wl.buffer,
	curWidth:   int,
	curHeight:  int,
	quit:       bool,
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


////////////////////////////////////////////////////////////////////////////////
// seat
seat_name :: proc "c" (data: rawptr, seat: ^wl.seat, name: cstring) {
	context = global_context
	fmt.println("seat name: ", name)
}

seat_capabilities :: proc "c" (data: rawptr, seat: ^wl.seat, capabilities: wl.seat_capability) {
	context = global_context

	have_pointer := cast(bool)(capabilities & wl.seat_capability.pointer)
	have_keyboard := cast(bool)(capabilities & wl.seat_capability.keyboard)

	if have_pointer && zooWindow.pointer == nil {
		zooWindow.pointer = wl.seat_get_pointer(seat)
		wl.pointer_add_listener(zooWindow.pointer, &pointer_listener, nil)
	} else if !have_pointer && zooWindow.pointer != nil {
		wl.pointer_release(zooWindow.pointer)
		zooWindow.pointer = nil
	}

	if have_keyboard && zooWindow.keyboard == nil {
		zooWindow.keyboard = wl.seat_get_keyboard(seat)
		wl.keyboard_add_listener(zooWindow.keyboard, &kbd_listener, nil)
	} else if !have_keyboard && zooWindow.keyboard != nil {
		wl.keyboard_release(zooWindow.keyboard)
		zooWindow.keyboard = nil
	}
}

seat_listener := wl.seat_listener {
	name         = seat_name,
	capabilities = seat_capabilities,
}


////////////////////////////////////////////////////////////////////////////////
// pointer

pointer_enter :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	serial: uint,
	surface: ^wl.surface,
	x: i32,
	y: i32,
) {
}

pointer_leave :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	serial: uint,
	surface: ^wl.surface,
) {
}

pointer_motion :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	time_: uint,
	surface_x_: i32,
	surface_y_: i32,
) {
}

pointer_button :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	serial_: uint,
	time_: uint,
	button_: uint,
	state_: wl.pointer_button_state,
) {
}

pointer_axis :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	time_: uint,
	axis_: wl.pointer_axis,
	amount_: i32,
) {
}

pointer_frame :: proc "c" (data: rawptr, pointer: ^wl.pointer) {
}

pointer_axis_source :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	axis_source: wl.pointer_axis_source,
) {
}

pointer_axis_stop :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	time: uint,
	axis: wl.pointer_axis,
) {
}

pointer_axis_discrete :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	axis: wl.pointer_axis,
	discrete: int,
) {
}

pointer_axis_value120 :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	axis: wl.pointer_axis,
	value120: int,
) {
}

pointer_axis_relative_direction :: proc "c" (
	data: rawptr,
	pointer: ^wl.pointer,
	axis: wl.pointer_axis,
	direction: wl.pointer_axis_relative_direction,
) {
}

pointer_listener := wl.pointer_listener {
	enter                   = pointer_enter,
	leave                   = pointer_leave,
	motion                  = pointer_motion,
	button                  = pointer_button,
	axis                    = pointer_axis,
	frame                   = pointer_frame,
	axis_source             = pointer_axis_source,
	axis_stop               = pointer_axis_stop,
	axis_discrete           = pointer_axis_discrete,
	axis_value120           = pointer_axis_value120,
	axis_relative_direction = pointer_axis_relative_direction,
}


////////////////////////////////////////////////////////////////////////////////
// keyboard
kbd_keymap :: proc "c" (
	data: rawptr,
	keyboard: ^wl.keyboard,
	format_: wl.keyboard_keymap_format,
	fd_: int,
	size_: uint,
) {
}

kbd_enter :: proc "c" (
	data: rawptr,
	keyboard: ^wl.keyboard,
	serial: uint,
	surface: ^wl.surface,
	keys: wl.array,
) {
}

kbd_leave :: proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial: uint, surface: ^wl.surface) {
}

kbd_key :: proc "c" (
	data: rawptr,
	keyboard: ^wl.keyboard,
	serial: uint,
	time: uint,
	key: uint,
	state: wl.keyboard_key_state,
) {
}

kbd_modifiers :: proc "c" (
	data: rawptr,
	keyboard: ^wl.keyboard,
	serial: uint,
	mods_depressed: uint,
	mods_latched: uint,
	mods_locked: uint,
	group: uint,
) {
}

kbd_repeat_info :: proc "c" (data: rawptr, keyboard: ^wl.keyboard, rate: int, delay: int) {
}

kbd_listener := wl.keyboard_listener {
	keymap      = kbd_keymap,
	enter       = kbd_enter,
	leave       = kbd_leave,
	key         = kbd_key,
	modifiers   = kbd_modifiers,
	repeat_info = kbd_repeat_info,
}

////////////////////////////////////////////////////////////////////////////////
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

	// --- Seat Setup ---
	wl.seat_add_listener(zooWindow.seat, &seat_listener, nil)

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
