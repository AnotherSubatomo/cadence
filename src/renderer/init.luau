
--!strict
--!optimize 2
--!native

const render2d_init = require("@self/2d")
const render3d_init = require("@self/3d")

return function (max_resolution: vector, view_resolution: vector?)
	const IMAGE_MEMSIZE = max_resolution.x * max_resolution.y * 4
	const IMAGE = buffer.create(IMAGE_MEMSIZE)
	const W = buffer.create(IMAGE_MEMSIZE)

	const function GET_IMAGE_BUFFER(): (buffer)
		return IMAGE
	end

	const function CLEAR(): ()
		buffer.fill(W, 0, 0)
		buffer.fill(IMAGE, 0, 255)
	end

	return {
		canvas = render2d_init(IMAGE, max_resolution, view_resolution),
		scene = render3d_init(IMAGE, W, max_resolution, view_resolution),
		
		getImageBuffer = GET_IMAGE_BUFFER,
		clear = CLEAR,
	}
end