
-- A small CLI that enables cadence to be rendered on
-- the web and its runtime to be quickly rebooted,
-- enabling rapid testing, prototyping, and debugging.

-- Run `lute run cycle` to get started.
-- Input 'r'/'R' to quickly reboot the runtime.
-- Input anything else to exit.

--!strict
--!optimize 2
--!native

const net = require("@lute/net")
const manifest = require("@self/manifest")

const process = require("@std/process")
const task = require("@std/task")
const io = require("@std/io")

const PORT_URL = "http://localhost:" .. manifest.port
const RUNNER_CMD = {'lute', 'run', 'cycle/runner'}

print("Initiating new cycle session!")
task.spawn(process.run, RUNNER_CMD, nil)

while true do
	const action = io.input():sub(1, 1)

	net.client.request(PORT_URL, {
		method = "POST",
		headers = { connection = "Shutdown" }
	})

	-- Recycle (i.e. reload runtime)
	if action == "r" or action == "R" then
		task.wait(manifest.shutdown_delay)
		task.spawn(process.run, RUNNER_CMD, nil)

	-- Exit cycle
	else
		print("Exiting cycle session.")
		break
	end
end