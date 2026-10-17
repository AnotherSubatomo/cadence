
--!strict
--!optimize 2
--!native

type JS_InputPacket = {
	x: number,
	y: number,
	dx: number,
	dy: number,
	mouse_states: number,
	right: number,
	up: number,
	forward: number,
}

type JS_ResizePacket = {
	width: number,
	height: number,
}

const json = require("@std/json")
const task = require("@std/task")
const net = require("@lute/net")
const fs = require("@std/fs")

type ServerSocket = net.ServerWebSocket

const program = require("./src")
const max_resolution = program.max_resolution

const FPS_DELTA = 1/60
const SITE_PORT = 8000
const WEBSOCKET_PORT = 8080

local CURRENT_PROGRAM_RUNTIME: thread?

const function main_loop(ws: ServerSocket): ()
	while true do
		task.wait(FPS_DELTA)

		const image = program.frame(FPS_DELTA)
		const debug_info = program.get_debug_info()
		const budget = debug_info.budget_consumed_percent * 1000 // 1 / 1000

		ws:send(image)
		ws:send( json.serialize {
			case = "debug",
			budget = budget,
		})
	end
end

const function ws_client_resize(ws: ServerSocket, width: number, height: number): ()
	ws:send( json.serialize {
		case = "resize",
		width = width,
		height = height,
	})
end

const function on_server_ws_open(ws: ServerSocket): ()
	print("[Server]: Websocket opened!")

	-- Initially send the set-up data...
	ws_client_resize(ws, max_resolution.x, max_resolution.y)

	task.wait(1)

	-- ...then, continuously feed the image data.
	CURRENT_PROGRAM_RUNTIME = task.spawn(main_loop, ws)
end

const function on_server_ws_message(ws: ServerSocket, message: string | buffer): ()
	if type(message) == "buffer" then return end
	const json_data = json.deserialize(message) :: {case: string} & {any}
	if typeof(json_data) ~= "table" then return end
	const json_case = json_data.case

	if json_case == "input" then
		const packet = json_data :: JS_InputPacket
		program.set_input(
			vector.create(packet.x, packet.y),
			vector.create(packet.dx, packet.dy),
			vector.create(
				bit32.btest(packet.mouse_states, 0b001) and 1 or 0,
				bit32.btest(packet.mouse_states, 0b010) and 1 or 0,
				bit32.btest(packet.mouse_states, 0b100) and 1 or 0
			),
			vector.create(packet.right, packet.up, packet.forward)
		)
	elseif json_case == "resize" then
		const packet = json_data :: JS_ResizePacket
		program.set_view_resolution(vector.create(packet.width, packet.height))
		ws_client_resize(ws, packet.width, packet.height)
		-- ^ send it back to validate resize request
	end
end

const function on_server_ws_close(ws: ServerSocket, code: number, message: string): ()
	print("[Server]: Websocket closed!")

	if CURRENT_PROGRAM_RUNTIME then
		task.cancel(CURRENT_PROGRAM_RUNTIME)
		CURRENT_PROGRAM_RUNTIME = nil
	end
end

const function handler(request: net.ReceivedRequest, server: net.Server): (net.ServerResponse)
	return fs.readFileToString('./web/index.html')
end

-- Start the site server
net.server.serve({
	port = SITE_PORT,
	handler = handler,
})

print(`[Server]: Site is now being hosted at {SITE_PORT}!`)

-- Start the server websocket
net.server.serve({
	port = WEBSOCKET_PORT,
	websocket = {
		open = on_server_ws_open,
		message = on_server_ws_message,
		close = on_server_ws_close,
	}
})

print(`[Server]: Websocket is now being hosted at {WEBSOCKET_PORT}!`)