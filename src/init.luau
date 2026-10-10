
--!strict
--!optimize 2
--!native

-- Renderer constants
const MAX_RESOLUTION = vector.create(4 * 85, 3 * 85)

-- Demo constants

const SPEED = 8
const SENSITIVITY = 0.5

-- Require assets
const renderer = require("./src/renderer")(MAX_RESOLUTION)
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

local MOVE_DIRECTION = vector.zero
local MOUSE_DELTA = vector.zero

const DEBUG_INFO = { budget_consumed_percent = 0 }

const function sync_input_events(delta: number): ()
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

const function sync_object_events(delta: number): ()
end

const function FRAME(delta: number): (buffer)
	sync_input_events(delta)
	sync_object_events(delta)

	const start_tick = os.clock()
	renderer.clear()
	renderer.scene.render()
	const end_tick = os.clock()

	DEBUG_INFO.budget_consumed_percent = ((end_tick - start_tick) / delta) * 100

	return IMAGE
end

const function SET_INPUT(new_mouse_delta: vector, new_move_direction: vector): ()
	MOVE_DIRECTION = new_move_direction
	MOUSE_DELTA = new_mouse_delta
end

const function GET_DEBUG_INFO()
	return DEBUG_INFO
end

return {
	max_resolution = MAX_RESOLUTION,
	frame = FRAME,
	set_input = SET_INPUT,
	set_view_resolution = renderer.scene.setViewResolution,
	get_debug_info = GET_DEBUG_INFO, 
}