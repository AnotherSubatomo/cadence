
--!strict
--!optimize 2
--!native

const render2d_init = require("@self/2d")
const render3d_init = require("@self/3d")

return function (max_resolution: vector, view_resolution: vector?)
	const IMAGE_MEMSIZE = max_resolution.x * max_resolution.y * 4
	const IMAGE = buffer.create(IMAGE_MEMSIZE)
	const W = buffer.create(IMAGE_MEMSIZE)

	const CANVAS = render2d_init(IMAGE, W, max_resolution, view_resolution)
	const SCENE = render3d_init(IMAGE, W, max_resolution, view_resolution)

	const function GET_IMAGE_BUFFER(): (buffer)
		return IMAGE
	end

	const function SET_RENDER_RESOLUTION(render_resolution: vector): ()
		CANVAS.setRenderResolution(render_resolution)
		SCENE.setRenderResolution(render_resolution)
	end

	const function CLEAR(): ()
		buffer.fill(W, 0, 0)
		buffer.fill(IMAGE, 0, 255)
	end

	return {
		canvas = CANVAS;
		scene = SCENE;
		
		setRenderResolution = SET_RENDER_RESOLUTION;
		getImageBuffer = GET_IMAGE_BUFFER;
		clear = CLEAR;
	}
end