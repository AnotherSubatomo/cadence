
-- cadence entry point.

--!strict
--!optimize 2
--!native

-- Renderer constants
const MAX_RESOLUTION = vector.create(4 * 85, 3 * 85)

-- Demo constants
const SPEED = 8
const SENSITIVITY = 1.5

-- Require assets
const renderer = require("./src/renderer")(MAX_RESOLUTION)
const ui = require("./src/ui")(renderer.canvas)
const obj_parser = require("./src/codec/obj")

const cube_mesh = obj_parser(require("./src/asset/cube"))
const missing_texture = require("./src/asset/missing")
const cube = renderer.scene.mesh(cube_mesh)
const missing = renderer.scene.texture(missing_texture)

const obj2 = renderer.scene.object(cube, missing)
renderer.scene.setObjectPosition(obj2, vector.create(0.625, 0, 1))

-- Prepare renderer runtime
const IMAGE = renderer.getImageBuffer()

local CAMERA_POSITION = vector.zero
local CAMERA_YAW, CAMERA_PITCH = 0, 0

local MOUSE_POSITION = vector.zero
local MOUSE_STATES = vector.zero
local MOUSE_DELTA = vector.zero
local MOVE_DIRECTION = vector.zero

const DEBUG_INFO = { budget_consumed_percent = 0 }

-- Persistent UI states
local clicks, flag, value = 0, true, 0.5

const function sync_input_events(delta: number): ()
	if MOUSE_STATES.z == 0 then return end

	CAMERA_YAW += MOUSE_DELTA.x * SENSITIVITY * delta
	CAMERA_PITCH += MOUSE_DELTA.y * SENSITIVITY * delta
	renderer.scene.setCameraRotation(CAMERA_YAW, CAMERA_PITCH)

	const right, up, forward = renderer.scene.getCameraBasis()
	const movement =
		forward * MOVE_DIRECTION.z -
		right   * MOVE_DIRECTION.x +
		up      * MOVE_DIRECTION.y

	CAMERA_POSITION += movement * SPEED * delta
	renderer.scene.setCameraPosition(CAMERA_POSITION)
end

const function sync_ui_render(): ()
	ui.begin(MOUSE_POSITION.x, MOUSE_POSITION.y, MOUSE_STATES.x == 1)

	--ui.panel(10, 10, 152, 119)
	ui.beginGroup(20, 20)

		ui.label("Hello, IMGUI!")
		ui.spacing()

		if ui.button("Click me") then clicks += 1 end
		ui.sameLine()
		ui.label("clicks: " .. clicks)

		ui.spacing()
		flag = ui.checkbox("Enable thing", flag)

		ui.spacing()
		value = ui.slider("Value", value, 0, 1, 132)

		ui.spacing()
		ui.progressBar(value, 0, 1, 132)

	ui.endGroup()
	ui.finish()
end

const function sync_scene_render(): ()
	renderer.scene.render()
end

const function FRAME(delta: number): (buffer)
	sync_input_events(delta)

	const start_tick = os.clock()
	renderer.clear()
	sync_ui_render()
	sync_scene_render()
	const end_tick = os.clock()

	DEBUG_INFO.budget_consumed_percent = ((end_tick - start_tick) / delta) * 100

	return IMAGE
end

const function SET_INPUT(
	new_mouse_position: vector,
	new_mouse_delta: vector,
	new_mouse_states: vector,
	new_move_direction: vector
): ()
	MOUSE_POSITION = new_mouse_position
	MOUSE_DELTA = new_mouse_delta
	MOUSE_STATES = new_mouse_states
	MOVE_DIRECTION = new_move_direction
end

const function GET_DEBUG_INFO()
	return DEBUG_INFO
end

return {
	max_resolution = MAX_RESOLUTION,
	frame = FRAME,
	set_input = SET_INPUT,
	set_view_resolution = renderer.setViewResolution,
	get_debug_info = GET_DEBUG_INFO, 
}