
--[=[
	3d - minimal, performant, platform agnostic 3D renderer in pure Luau.
	* Derived from  @AnotherSubatomo/kosmos
	Author: @AnotherSubatomo (GitHub)
	SPDX-License-Identifier: MPL-2.0
]=]

--[=[
	SUPPLEMENTARY INFORMATION ABOUT THE IMPLEMENTATION
	==================================================

	# Coordinate system: right-handed, Y-up, +W-forward

	# Vertex winding order: counter-clockwise = front-facing

	# Currently, the rendering pipeline looks like this:
	meshdata -> world transforms -> camera transforms ->
	culling -> clipping -> rasterization* -> output image

	Rasterization only accounts for depth and UV (for texture mapping);
	other per-vertex attributes such as color, transparency, and normals
	are not and will not be supported.

	# Depth interpolation conventions:
		This renderer operates in camera space where:
		z = forward distance from the camera (linear in 3D space)

		During rasterization, we use:
		w = 1 / z

		Reason:
		Perspective projection (x/z, y/z) makes attributes non-linear in screen space.
		However, 1/z varies linearly across the screen, so we interpolate w instead of z.

		Notes for experienced readers:
		- This "w" is NOT clip-space homogeneous w from a full graphics pipeline.
		- It is simply the reciprocal of camera-space z.
		- The depth buffer stores w (i.e., a w-buffer), not z.
		- Depth test uses: larger w = closer pixel.

		This matches the behavior of perspective-correct interpolation used in GPUs,
		without implementing a full homogeneous clip-space pipeline.
]=]

--!strict
--!optimize 2
--!native

-- Basic mesh data (allowed to be mutable)
export type raw_mesh = {
	vertices: {vector},
	uvs: {vector},
	faces: {vector}
}

-- A row-major, RGBA8 texture data, with a size equivalent
-- to `width` * `height` * 4. (allowed to be mutable)
export type texture = {
	width: number,
	height: number,
	data: buffer
}

export type mesh = {
	-- Mesh data reference directly derived from
	-- `raw_mesh` (also allowed to be mutable)
	vertices: {vector},
	uvs: {vector},
	faces: {vector},
	-- * Yes, mutability means that every final mutation
	--   would require a call of `recomputeMeshBounds()`
	--   for the recalculation of the following bounds:
	-- Axis-aligned bounds
	aabb_min: vector,
	aabb_max: vector,
	-- Spherical bounds
	sb_center: vector,
	sb_radius: number,
}

export type object = {
	mesh_id: number,
	texture_id: number,
	position: vector,
	right: vector,
	up: vector,
	forward: vector,
}

const ERR_SET_OBJ_DOESNT_EXIST = "Tried to change a property of a non-existant object."

const NEAR = 0.01
const FAR = 1000
const NO_TEXTURE_ID = 0

const VEC_INF = vector.one * math.huge
const VEC_NEG_INF = vector.one * -math.huge

const GLOBAL_RIGHT = vector.create(1, 0, 0)
const GLOBAL_UP = vector.create(0, 1, 0)
const GLOBAL_FORWARD = vector.create(0, 0, 1)

const SKYBOX_RADIUS = 1024

const DEFAULT_SKYBOX_TEXTURES = {NO_TEXTURE_ID, NO_TEXTURE_ID, NO_TEXTURE_ID, NO_TEXTURE_ID, NO_TEXTURE_ID, NO_TEXTURE_ID}
local SKYBOX_VERTICES: {vector}

const SUV_11 = vector.create(1, 1)
const SUV_01 = vector.create(0, 1)
const SUV_00 = vector.create(0, 0)
const SUV_10 = vector.create(1, 0)

do
	const SV_PPN = vector.create(SKYBOX_RADIUS, SKYBOX_RADIUS, -SKYBOX_RADIUS)
	const SV_NPN = vector.create(-SKYBOX_RADIUS, SKYBOX_RADIUS, -SKYBOX_RADIUS)
	const SV_NNN = vector.create(-SKYBOX_RADIUS, -SKYBOX_RADIUS, -SKYBOX_RADIUS)
	const SV_PNN = vector.create(SKYBOX_RADIUS, -SKYBOX_RADIUS, -SKYBOX_RADIUS)
	const SV_NPP = vector.create(-SKYBOX_RADIUS, SKYBOX_RADIUS, SKYBOX_RADIUS)
	const SV_PPP = vector.create(SKYBOX_RADIUS, SKYBOX_RADIUS, SKYBOX_RADIUS)
	const SV_PNP = vector.create(SKYBOX_RADIUS, -SKYBOX_RADIUS, SKYBOX_RADIUS)
	const SV_NNP = vector.create(-SKYBOX_RADIUS, -SKYBOX_RADIUS, SKYBOX_RADIUS)

	SKYBOX_VERTICES = {
		SV_PPN, SV_NPN, SV_NNN, SV_PNN, -- Front
		SV_NPP,	SV_PPP,	SV_PNP,	SV_NNP, -- Back
		SV_PPP,	SV_PPN,	SV_PNN,	SV_PNP, -- Left
		SV_NPN,	SV_NPP,	SV_NNP,	SV_NNN, -- Right
		SV_PPN,	SV_PPP,	SV_NPP,	SV_NPN, -- Top
		SV_PNP,	SV_PNN,	SV_NNN,	SV_NNP, -- Bottom
	}
end

const SKYBOX_FACES = {
	{1, 2, 3, 4}, -- Front
	{5, 6, 7, 8}, -- Back
	{9, 10, 11, 12}, -- Left
	{13, 14, 15, 16}, -- Right
	{17, 18, 19, 20}, -- Top
	{21, 22, 23, 24}, -- Bottom
}

const function intersect(a: vector, auv: vector, b: vector, buv: vector): (vector, vector)
	const ax, ay, az = a.x, a.y, a.z
	const dz = b.z - az

	if dz == 0 then
		return vector.create(ax, ay, NEAR), auv
	else
		const t = (NEAR - az) / dz
		return vector.create(
			ax + (b.x - ax) * t,
			ay + (b.y - ay) * t,
			NEAR
		), vector.lerp(auv, buv, t)
	end
end

return function (image: buffer, w: buffer, max_resolution: vector, view_resolution: vector?)
	const IMAGE_MEMSIZE = max_resolution.x * max_resolution.y * 4
	if buffer.len(image) ~= IMAGE_MEMSIZE then
		error "The given image buffer's size must be equal to the product of the given maximum resolution's `x` and `y` times 4."
	end
	if buffer.len(w) ~= IMAGE_MEMSIZE then
		error "The given W buffer's size must be equal to the product of the given maximum resolution's `x` and `y` times 4."
	end

	const IMAGE = image
	const W = w

	-- View settings
	local VIEW_RESOLUTION = view_resolution or max_resolution
	local VIEW_WIDTH = VIEW_RESOLUTION.x
	local VIEW_HEIGHT = VIEW_RESOLUTION.y
	local VIEW_ROW_OFFSET = VIEW_WIDTH * 4

	local WIDTH_M_1 = VIEW_WIDTH - 1
	local HEIGHT_M_1 = VIEW_HEIGHT - 1
	local ASPECT_RATIO = VIEW_WIDTH / VIEW_HEIGHT

	-- Atmosphere settings
	local AMBIENT = 0.4 -- base light (0–1)
	local LIGHT_DIR = vector.normalize(vector.one)

	const SKYBOX_TEXTURES = table.clone(DEFAULT_SKYBOX_TEXTURES)
	const SKYBOX_TRANSFORMS = table.create(24) :: {vector}
	
	-- Camera settings
	local POSITION = vector.zero
	local WORLD_UP = vector.create(0, 1, 0)
	local YAW, PITCH, ROLL = 0, 0, 0

	local CAMERA_DIRTY = false

	-- Derived camera settings
	local RIGHT = GLOBAL_RIGHT
	local UP = GLOBAL_UP
	local FORWARD = GLOBAL_FORWARD

	local TAN_Y = math.tan(math.rad(90) * 0.5)
	local TAN_X = TAN_Y * ASPECT_RATIO

	local INV_TAN_Y = 1 / TAN_Y
	local INV_TAN_X = 1 / TAN_X

	local LEN_Y = math.sqrt(1 + TAN_Y * TAN_Y)
	local LEN_X = math.sqrt(1 + TAN_X * TAN_X)

	-- Recomputes the orthogonal bases according to the euler rotations given.
	const function calculate_basis(yaw: number, pitch: number, roll: number): (vector, vector, vector)
		const cy = math.cos(yaw)
		const sy = math.sin(yaw)
		const cp = math.cos(pitch)
		const sp = math.sin(pitch)

		local forward = vector.create(sy * cp, -sp, cy * cp)

		local right = vector.normalize(vector.cross(WORLD_UP, forward))

		-- Recompute up to ensure orthogonality
		local up = vector.normalize(vector.cross(forward, right))

		-- Apply roll (rotate right/up around forward)
		if roll ~= 0 then
			const cr = math.cos(roll)
			const sr = math.sin(roll)

			const r = right * cr + up * sr
			const u = up * cr - right * sr

			right = r
			up = u
		end

		return right, up, forward
	end

	const function GET_CAMERA_BASIS(): (vector, vector, vector)
		return RIGHT, UP, FORWARD
	end

	const function SET_CAMERA_POSITION(position: vector?): ()
		if not position or position == POSITION then return end
		POSITION = position
		CAMERA_DIRTY = true
	end

	const function SET_CAMERA_ROTATION(yaw: number?, pitch: number?, roll: number?, world_up: vector?): ()
		if yaw      and yaw      ~= YAW      then YAW      = yaw      end
		if pitch    and pitch    ~= PITCH    then PITCH    = pitch    end
		if roll     and roll     ~= ROLL     then ROLL     = roll     end
		if world_up and world_up ~= WORLD_UP then WORLD_UP = world_up end
		RIGHT, UP, FORWARD = calculate_basis(YAW, PITCH, ROLL)
		CAMERA_DIRTY = true
	end

	const function SET_FIELD_OF_VIEW(fov_degree: number): ()
		TAN_Y = math.tan(math.rad(fov_degree) * 0.5)
		TAN_X = TAN_Y * ASPECT_RATIO

		INV_TAN_Y = 1 / TAN_Y
		INV_TAN_X = 1 / TAN_X

		LEN_Y = math.sqrt(1 + TAN_Y * TAN_Y)
		LEN_X = math.sqrt(1 + TAN_X * TAN_X)
		CAMERA_DIRTY = true
	end

	const function SET_LIGHTING_AMBIENT(ambient: number): ()
		if not ambient or ambient == AMBIENT then return end
		AMBIENT = ambient
	end

	const function SET_LIGHTING_DIRECTION(direction: vector): ()
		if not direction or direction == LIGHT_DIR then return end
		LIGHT_DIR = vector.normalize(direction)
	end

	const function SET_SKYBOX_TEXTURES(
		front_id: number?, back_id: number?,
		left_id: number?, right_id: number?,
		top_id: number?, bottom_id: number?
	): ()
		if front_id  and front_id  ~= SKYBOX_TEXTURES[1] then SKYBOX_TEXTURES[1] = front_id  end	
		if back_id   and back_id   ~= SKYBOX_TEXTURES[2] then SKYBOX_TEXTURES[2] = back_id   end
		if left_id   and left_id   ~= SKYBOX_TEXTURES[3] then SKYBOX_TEXTURES[3] = left_id   end
		if right_id  and right_id  ~= SKYBOX_TEXTURES[4] then SKYBOX_TEXTURES[4] = right_id  end
		if top_id    and top_id    ~= SKYBOX_TEXTURES[5] then SKYBOX_TEXTURES[5] = top_id    end
		if bottom_id and bottom_id ~= SKYBOX_TEXTURES[6] then SKYBOX_TEXTURES[6] = bottom_id end
	end

	const function SET_VIEW_RESOLUTION(view_resolution: vector): ()
		const view_width = view_resolution.x
		const view_height = view_resolution.y

		if view_width < 0 or view_height < 0 then
			error "Invalid view resolution"
		end
		if view_width > max_resolution.x then
			error "New view width cannot be greater than the max width"
		end
		if view_height > max_resolution.y then
			error "New view height cannot be greater than the max height"
		end

		VIEW_RESOLUTION = view_resolution
		VIEW_WIDTH = view_width
		VIEW_HEIGHT = view_height
		VIEW_ROW_OFFSET = VIEW_WIDTH * 4

		WIDTH_M_1 = VIEW_WIDTH - 1
		HEIGHT_M_1 = VIEW_HEIGHT - 1
		ASPECT_RATIO = VIEW_WIDTH / VIEW_HEIGHT

		-- Recalculate FOV for the x-axis
		TAN_X = TAN_Y * ASPECT_RATIO
		INV_TAN_X = 1 / TAN_X
		LEN_X = math.sqrt(1 + TAN_X * TAN_X)
	end

	-- Projects the vertex into screen space. (the unmodified `z` is also returned)
	const function project_to_screen(v: vector): (number, number, number)
		const z = v.z
		const px = (v.x/z) * INV_TAN_X
		const py = (v.y/z) * INV_TAN_Y

		return 
			((px + 1) * 0.5 * WIDTH_M_1) // 1,
			((1 - (py + 1) * 0.5) * HEIGHT_M_1) // 1,
			z
	end

	-- Sphere-based frustum culling.
	const function is_frustum_culled(object: object, mesh: mesh): (boolean)
		const center_local = mesh.sb_center

		const center_world = object.position
			+ object.right   * center_local.x
			+ object.up      * center_local.y
			+ object.forward * center_local.z

		const center_view = center_world - POSITION

		const cx = vector.dot(center_view, RIGHT)
		const cy = vector.dot(center_view, UP)
		const cz = vector.dot(center_view, FORWARD)

		const r = mesh.sb_radius

		if cz + r < NEAR then return true end -- Near
		if cz - r > FAR then return true end -- Far

		-- Frustum slope terms (z-scaled half-extents)
		const half_width = cz * TAN_X
		const half_height = cz * TAN_Y

		-- Plane constants (sphere radius projected onto plane normals)
		const plane_offset_x = -(r * LEN_X)
		const plane_offset_y = -(r * LEN_Y)

		if  cx + half_width < plane_offset_x then return true end -- Left
		if -cx + half_width < plane_offset_x then return true end -- Right

		if  cy + half_height < plane_offset_y then return true end -- Top
		if -cy + half_height < plane_offset_y then return true end -- Bottom

		return false
	end

	-- Transforms the set of vertices into world + camera space;
	-- also recomputes the mesh bounds local to the mesh itself.
	const function transform(mesh: mesh, object: object, transforms: {vector}, recompute_mesh_bounds: boolean): ()
		-- * commented since it's implicitly overwritten, though
		--   when it makes more sense, I might uncomment it...
		--table.clear(transforms)

		const position = object.position
		const right = object.right
		const up = object.up
		const forward = object.forward

		if recompute_mesh_bounds then
			local aabb_min = VEC_INF
			local aabb_max = VEC_NEG_INF

			for i, v in mesh.vertices do
				-- Calculate mesh-local AABB
				aabb_min = vector.min(aabb_min, v)
				aabb_max = vector.max(aabb_max, v)

				-- Local-space -> world-space transformations
				const rot_v = vector.create(
					vector.dot(v, right),
					vector.dot(v, up),
					vector.dot(v, forward)
				)

				-- World-space -> camera-space transformations
				-- `rot_v + position` is still world-space, `- POSITION` is now camera-space
				const pos_v = rot_v + position - POSITION

				const cam_v = vector.create(
					vector.dot(pos_v, RIGHT),
					vector.dot(pos_v, UP),
					vector.dot(pos_v, FORWARD)
				)

				transforms[i] = cam_v
			end

			-- Calculate mesh-local spherical bounding (NOT assured to be optimal)
			const sb_center = (aabb_min + aabb_max) * 0.5
			const sb_radius = vector.magnitude(sb_center - aabb_min)

			mesh.aabb_min, mesh.aabb_max, mesh.sb_center, mesh.sb_radius =
				aabb_min, aabb_max, sb_center, sb_radius
		else
			for i, v in mesh.vertices do
				-- Local-space -> world-space transformations
				const rot_v = vector.create(
					vector.dot(v, right),
					vector.dot(v, up),
					vector.dot(v, forward)
				)

				-- World-space -> camera-space transformations
				-- `rot_v + position` is still world-space, `- POSITION` is now camera-space
				const pos_v = rot_v + position - POSITION

				const cam_v = vector.create(
					vector.dot(pos_v, RIGHT),
					vector.dot(pos_v, UP),
					vector.dot(pos_v, FORWARD)
				)

				transforms[i] = cam_v
			end
		end
	end

	local CV1: vector, CV2: vector, CV3: vector, CV4: vector, CV5: vector, CV6: vector
	local CT1: vector, CT2: vector, CT3: vector, CT4: vector, CT5: vector, CT6: vector

	-- Clips triangles near the camera plane into y-monotone triangle/s. (or none, where the triangle gets skipped)
	const function clip_triangle(a: vector, b: vector, c: vector, at: vector, bt: vector, ct: vector): (number)
		const ai = a.z >= NEAR
		const bi = b.z >= NEAR
		const ci = c.z >= NEAR

		const count = (ai and 1 or 0) + (bi and 1 or 0) + (ci and 1 or 0)

		-- Fully inside
		if count == 3 then
			CV1, CV2, CV3 = a, b, c
			CT1, CT2, CT3 = at, bt, ct
			return 1
		end

		-- Fully outside
		if count == 0 then
			return 0
		end

		-- 1 inside --> 1 triangle
		if count == 1 then
			local inV, outV1, outV2
			local inT, outT1, outT2

			if ai then
				inV, outV1, outV2 = a, b, c
				inT, outT1, outT2 = at, bt, ct
			elseif bi then
				inV, outV1, outV2 = b, c, a
				inT, outT1, outT2 = bt, ct, at
			else
				inV, outV1, outV2 = c, a, b
				inT, outT1, outT2 = ct, at, bt
			end

			CV1, CT1 = inV, inT
			CV2, CT2 = intersect(inV, inT, outV1, outT1)
			CV3, CT3 = intersect(inV, inT, outV2, outT2)

			return 1
		end

		-- 2 inside --> quad --> 2 triangles
		local outV, inV1, inV2
		local outT, inT1, inT2

		if not ai then
			outV, inV1, inV2 = a, b, c
			outT, inT1, inT2 = at, bt, ct
		elseif not bi then
			outV, inV1, inV2 = b, c, a
			outT, inT1, inT2 = bt, ct, at
		else
			outV, inV1, inV2 = c, a, b
			outT, inT1, inT2 = ct, at, bt
		end

		local iV1, iT1 = intersect(inV1, inT1, outV, outT)
		local iV2, iT2 = intersect(inV2, inT2, outV, outT)

		-- First triangle
		CV1, CV2, CV3 = inV1, inV2, iV1
		CT1, CT2, CT3 = inT1, inT2, iT1

		-- Second triangle
		CV4, CV5, CV6 = inV2, iV2, iV1
		CT4, CT5, CT6 = inT2, iT2, iT1

		return 2
	end

	-- Rasterizes a triangle.
	const function draw_triangle(
		a: vector, b: vector, c: vector,
		at: vector, bt: vector, ct: vector,
		tw: number, th: number, trs: number, td: buffer,
		shade_factor: number
	): ()
		-- Screen-space projection
		local ax, ay, az = project_to_screen(a)
		local bx, by, bz = project_to_screen(b)
		local cx, cy, cz = project_to_screen(c)

		-- Sort vertices (along with their UV) by ascending Y [c (bottom) -> b -> a (top)]
		if ay > by then ax, ay, az, at, bx, by, bz, bt = bx, by, bz, bt, ax, ay, az, at end
		if ay > cy then ax, ay, az, at, cx, cy, cz, ct = cx, cy, cz, ct, ax, ay, az, at end
		if by > cy then bx, by, bz, bt, cx, cy, cz, ct = cx, cy, cz, ct, bx, by, bz, bt end

		-- Reject degenerate triangle
		if ay == cy then return end

		-- Precompute vertical distances for interpolation along triangle edges
		local dy_ab = by - ay
		local dy_ac = cy - ay
		local dy_bc = cy - by

		-- Compute reciprocal depth (w = 1/z) for perspective-correct interpolation
		local aw = 1/az
		local bw = 1/bz
		local cw = 1/cz

		-- Pre-multiply UVs by `w` so they interpolate linearly in screen space
		local auw = at.x * aw
		local avw = at.y * aw

		local buw = bt.x * bw
		local bvw = bt.y * bw

		local cuw = ct.x * cw
		local cvw = ct.y * cw

		-- Calculate slopes for incremental interpolation
		-- Edge slopes:
		local m_ab, m_ac, m_bc = 0, 0, 0
		-- Depth slopes:
		local mw_ab, mw_ac, mw_bc = 0, 0, 0
		-- UV slopes:
		local muw_ab, mvw_ab = 0, 0
		local muw_ac, mvw_ac = 0, 0
		local muw_bc, mvw_bc = 0, 0

		-- (the if statements guard against division by zero for flat edges)
		if dy_ab ~= 0 then
			m_ab = (bx - ax) / dy_ab
			mw_ab = (bw - aw) / dy_ab
			muw_ab = (buw - auw) / dy_ab
			mvw_ab = (bvw - avw) / dy_ab
		end

		if dy_ac ~= 0 then
			m_ac = (cx - ax) / dy_ac
			mw_ac = (cw - aw) / dy_ac
			muw_ac = (cuw - auw) / dy_ac
			mvw_ac = (cvw - avw) / dy_ac
		end

		if dy_bc ~= 0 then
			m_bc = (cx - bx) / dy_bc
			mw_bc = (cw - bw) / dy_bc
			muw_bc = (cuw - buw) / dy_bc
			mvw_bc = (cvw - bvw) / dy_bc
		end

		-- Discretize to get scan bounds
		local y_start = ay // 1
		local y_end   = cy // 1

		-- Ensure correct ordering after discretization
		if y_start > y_end then y_start, y_end = y_end, y_start end

		-- Clamp to viewport height (prevents OOB buffer errors)
		y_start = math.max(0, y_start)
		y_end   = math.min(HEIGHT_M_1, y_end)

		-- Split the triangle!
		local y_middle = by // 1

		-- Clamp to scan bounds
		if y_middle < y_start then y_middle = y_start end
		if y_middle > y_end   then y_middle = y_end   end

		-- Precompute row offset into image buffer
		local row_stride = y_start * VIEW_ROW_OFFSET

		-- Rasterize the top half of triangle (a --> b)
		for y = y_start, y_middle - 1 do
			-- Compute the general blend factor
			local lt = (y - ay)
			local rt = (y - ay)

			-- Compute left/right X positions of the scanline
			local lx = ax + lt * m_ab
			local rx = ax + rt * m_ac

			-- Interpolate depth along edges
			local lw = aw + lt * mw_ab
			local rw = aw + rt * mw_ac

			-- Interpolate UV along edges
			local luw = auw + lt * muw_ab
			local ruw = auw + rt * muw_ac

			local lvw = avw + lt * mvw_ab
			local rvw = avw + rt * mvw_ac

			-- Ensure left-to-right ordering
			if lx > rx then
				lx, rx = rx, lx
				lw, rw = rw, lw
				luw, ruw = ruw, luw
				lvw, rvw = rvw, lvw
			end

			-- Clamp horizontal span to screen bounds
			local x_start = math.max(0, (lx + 0.5) // 1)
			local x_end   = math.min(WIDTH_M_1, rx // 1)
			local offset  = row_stride + x_start * 4

			-- Compute per-pixel slopes across scanline
			local dx_lr = rx - lx
			local m_wx, m_uwx, m_vwx = 0, 0, 0

			if dx_lr ~= 0 then
				m_wx = (rw - lw) / dx_lr
				m_uwx = (ruw - luw) / dx_lr
				m_vwx = (rvw - lvw) / dx_lr
			end

			-- Adjust starting values (prevents distortion)
			local dx = x_start - lx
			local w = lw + dx * m_wx
			local uw = luw + dx * m_uwx
			local vw = lvw + dx * m_vwx

			-- Fill pixels across scanline
			for _ = x_start, x_end do
				if w > buffer.readf32(W, offset) then
					-- Recover perspective-correct UVs
					local inv_w = 1 / w
					local u = uw * inv_w
					local v = vw * inv_w

					u -= u // 1
					v -= v // 1

					-- Map to texture
					local s = (u * tw) // 1
					local t = (v * th) // 1
					local texture_color = buffer.readu32(td, t * trs + s * 4)

					-- Blend the texture to the shading
					local rb = bit32.band(texture_color, 0x00FF00FF) * shade_factor
					local g = bit32.band(texture_color, 0x0000FF00) * shade_factor

					rb = bit32.band(bit32.rshift(rb, 8), 0x00FF00FF)
					g = bit32.band(bit32.rshift(g, 8), 0x0000FF00)

					local color = 0xFF000000 + rb + g

					buffer.writeu32(IMAGE, offset, color)
					buffer.writef32(W, offset, w)
				end

				-- Step interpolants (& byte offset) across X
				w += m_wx
				uw += m_uwx
				vw += m_vwx
				offset += 4
			end

			row_stride += VIEW_ROW_OFFSET
		end

		-- Adjust the split if discretization misses the true middle scanline
		local y_middle_adj = y_middle + (y_middle < by and 1 or 0)

		-- Rasterize bottom half of triangle (b --> c)
		for y = y_middle_adj, y_end do
			-- Compute the general blend factor
			local lt = (y - by)
			local rt = (y - ay)

			-- Compute left/right X positions of the scanline
			local lx = bx + lt * m_bc
			local rx = ax + rt * m_ac

			-- Interpolate depth along edges
			local lw = bw + lt * mw_bc
			local rw = aw + rt * mw_ac

			-- Interpolate UV along edges
			local luw = buw + lt * muw_bc
			local ruw = auw + rt * muw_ac

			local lvw = bvw + lt * mvw_bc
			local rvw = avw + rt * mvw_ac

			-- Ensure left-to-right ordering
			if lx > rx then
				lx, rx = rx, lx
				lw, rw = rw, lw
				luw, ruw = ruw, luw
				lvw, rvw = rvw, lvw
			end

			-- Clamp horizontal span to screen bounds
			local x_start = math.max(0, (lx + 0.5) // 1)
			local x_end   = math.min(WIDTH_M_1, rx // 1)
			local offset  = row_stride + x_start * 4

			-- Compute per-pixel slopes across scanline
			local dx_lr = rx - lx
			local m_wx, m_uwx, m_vwx = 0, 0, 0

			if dx_lr ~= 0 then
				m_wx = (rw - lw) / dx_lr
				m_uwx = (ruw - luw) / dx_lr
				m_vwx = (rvw - lvw) / dx_lr
			end

			-- Adjust starting values (prevents distortion)
			local dx = x_start - lx
			local w = lw + dx * m_wx
			local uw = luw + dx * m_uwx
			local vw = lvw + dx * m_vwx

			-- Fill pixels across scanline
			for _ = x_start, x_end do
				if w > buffer.readf32(W, offset) then
					-- Recover perspective-correct UVs
					local inv_w = 1 / w
					local u = uw * inv_w
					local v = vw * inv_w

					u -= u // 1
					v -= v // 1

					-- Map to texture
					local s = (u * tw) // 1
					local t = (v * th) // 1
					local texture_color = buffer.readu32(td, t * trs + s * 4)

					-- Blend the texture to the shading
					local rb = bit32.band(texture_color, 0x00FF00FF) * shade_factor
					local g = bit32.band(texture_color, 0x0000FF00) * shade_factor

					rb = bit32.band(bit32.rshift(rb, 8), 0x00FF00FF)
					g = bit32.band(bit32.rshift(g, 8), 0x0000FF00)

					local color = 0xFF000000 + rb + g

					buffer.writeu32(IMAGE, offset, color)
					buffer.writef32(W, offset, w)
				end

				-- Step interpolants (& byte offset) across X
				w += m_wx
				uw += m_uwx
				vw += m_vwx
				offset += 4
			end

			row_stride += VIEW_ROW_OFFSET
		end
	end

	const MESHES = table.create(4) :: {mesh}
	const MESH_RECOMPUTE_STATE = table.create(4) :: {boolean}

	const TEXTURES = table.create(4) :: {texture}

	const OBJECTS = table.create(16) :: {object}
	const OBJECTS_CHANGED = table.create(16) :: {boolean}
	const OBJECT_TRANSFORMS = table.create(16) :: {{vector}}

	const function MESH(raw_mesh: raw_mesh): (number)
		const vertices = raw_mesh.vertices

		const mesh = {
			vertices = vertices,
			uvs = raw_mesh.uvs,
			faces = raw_mesh.faces,

			-- * Computation is defered to `transform()`
			aabb_min = vector.zero,
			aabb_max = vector.zero,
			sb_center = vector.zero,
			sb_radius = 0,
		}

		table.insert(MESHES, mesh)
		table.insert(MESH_RECOMPUTE_STATE, true)
		return #MESHES
	end

	const function TEXTURE(texture: texture): (number)
		table.insert(TEXTURES, texture)
		return #TEXTURES
	end

	const function OBJECT(mesh_id: number, texture_id: number?): (number)
		const mesh = MESHES[mesh_id]
		if not mesh then error "Tried to create an object for a non-existant mesh." end

		const object_id = #OBJECTS + 1
		const valid_texture_id =
			if texture_id and TEXTURES[texture_id]
			then texture_id else NO_TEXTURE_ID

		const object = {
			mesh_id = mesh_id,
			texture_id = valid_texture_id,
			position = vector.zero,
			right = GLOBAL_RIGHT,
			up = GLOBAL_UP,
			forward = GLOBAL_FORWARD,
		}

		OBJECTS[object_id] = object
		OBJECTS_CHANGED[object_id] = false

		-- Create draw entry *once*
		OBJECT_TRANSFORMS[object_id] = table.create(#mesh.vertices) :: {vector}

		return object_id
	end

	const function RECOMPUTE_MESH_BOUNDS(mesh_id: number): ()
		const mesh = MESHES[mesh_id]
		if not mesh then error "Tried to recompute the bounds of a non-existant mesh." end
		MESH_RECOMPUTE_STATE[mesh_id] = true
	end

	const function GET_MESH_AABB(mesh_id: number): (vector, vector)
		const mesh = MESHES[mesh_id]
		if not mesh then error "Tried to get the axis-aligned bounds of a non-existant mesh." end
		return mesh.aabb_min, mesh.aabb_max
	end

	const function GET_MESH_SB(mesh_id: number): (vector, number)
		const mesh = MESHES[mesh_id]
		if not mesh then error "Tried to get the spherical bounds of a non-existant mesh." end
		return mesh.sb_center, mesh.sb_radius
	end

	const function SET_OBJECT_MESH(object_id: number, mesh_id: number): ()
		const object = OBJECTS[object_id]
		if not object then error(ERR_SET_OBJ_DOESNT_EXIST) end
		object.mesh_id = mesh_id
		OBJECTS_CHANGED[object_id] = true
	end

	const function SET_OBJECT_TEXTURE(object_id: number, texture_id: number): ()
		const object = OBJECTS[object_id]
		if not object then error(ERR_SET_OBJ_DOESNT_EXIST) end
		object.texture_id = texture_id
		OBJECTS_CHANGED[object_id] = true
	end

	const function SET_OBJECT_POSITION(object_id: number, position: vector): ()
		const object = OBJECTS[object_id]
		if not object then error(ERR_SET_OBJ_DOESNT_EXIST) end
		object.position = position
		OBJECTS_CHANGED[object_id] = true
	end

	const function SET_OBJECT_ROTATION(object_id: number, yaw: number, pitch: number, roll: number): ()
		const object = OBJECTS[object_id]
		if not object then error(ERR_SET_OBJ_DOESNT_EXIST) end
		object.right, object.up, object.forward = calculate_basis(yaw, pitch, roll)
		OBJECTS_CHANGED[object_id] = true
	end

	const function RENDER(): ()
		-- Transform light direction
		const light_direction = vector.create(
			vector.dot(LIGHT_DIR, RIGHT),
			vector.dot(LIGHT_DIR, UP),
			vector.dot(LIGHT_DIR, FORWARD)
		)

		-- Render objects
		for object_id, object in OBJECTS do
			const texture_id = object.texture_id
			if texture_id == NO_TEXTURE_ID then continue end

			const mesh_id = object.mesh_id
			const mesh = MESHES[mesh_id]
			const transforms = OBJECT_TRANSFORMS[object_id]

			if is_frustum_culled(object, mesh) then continue end

			-- Resolve necessary transforms
			if CAMERA_DIRTY or OBJECTS_CHANGED[object_id] then
				const recompute_mesh_bounds = MESH_RECOMPUTE_STATE[mesh_id]
				transform(mesh, object, transforms, recompute_mesh_bounds)

				if recompute_mesh_bounds then
					MESH_RECOMPUTE_STATE[mesh_id] = false
				end

				OBJECTS_CHANGED[object_id] = false
			end

			-- Render the object
			const faces = mesh.faces
			const uvs = mesh.uvs
			const texture = TEXTURES[texture_id]

			const tw = texture.width - 1
			const th = texture.height - 1
			const trs = texture.width * 4
			const td = texture.data

			for _, face in faces do
				const ai = face.x
				const bi = face.y
				const ci = face.z

				const a = transforms[ai]
				const b = transforms[bi]
				const c = transforms[ci]

				-- Backface culling
				const ab = b - a
				const ac = c - a
				const normal = vector.cross(ab, ac)

				if vector.dot(normal, a) >= 0 then continue end

				const at = uvs[ai]
				const bt = uvs[bi]
				const ct = uvs[ci]

				-- Near plane triangle clipping
				const tri_count = clip_triangle(a, b, c, at, bt, ct)
				if tri_count == 0 then continue end
				
				-- Rasterizing and shading
				const NdotL = math.max(0, vector.dot(vector.normalize(normal), light_direction))
				const intensity = AMBIENT + (1 - AMBIENT) * NdotL
				const shade_factor = intensity * 255 // 1

				if tri_count == 1 then
					draw_triangle(CV1, CV2, CV3, CT1, CT2, CT3, tw, th, trs, td, shade_factor)
				elseif tri_count == 2 then
					draw_triangle(CV1, CV2, CV3, CT1, CT2, CT3, tw, th, trs, td, shade_factor)
					draw_triangle(CV4, CV5, CV6, CT4, CT5, CT6, tw, th, trs, td, shade_factor)
				end
			end
		end

		-- Transform skybox
		for i, v in SKYBOX_VERTICES do
			-- Camera-space transformation
			const cam_v = vector.create(
				vector.dot(v, RIGHT),
				vector.dot(v, UP),
				vector.dot(v, FORWARD)
			)

			SKYBOX_TRANSFORMS[i] = cam_v
		end

		-- Render skybox
		for index, face in SKYBOX_FACES do
			const texture_id = SKYBOX_TEXTURES[index]
			if texture_id == NO_TEXTURE_ID then continue end

			const texture = TEXTURES[texture_id]
			const tw = texture.width - 1
			const th = texture.height - 1
			const trs = texture.width * 4
			const td = texture.data

			const ai = face[1]
			const bi = face[2]
			const ci = face[3]
			const di = face[4]

			const a = SKYBOX_TRANSFORMS[ai]
			const b = SKYBOX_TRANSFORMS[bi]
			const c = SKYBOX_TRANSFORMS[ci]
			const d = SKYBOX_TRANSFORMS[di]

			local tri_count = 0

			-- Triangle one:
			tri_count = clip_triangle(a, c, b, SUV_11, SUV_00, SUV_01)
			if tri_count == 1 then
				draw_triangle(CV1, CV2, CV3, CT1, CT2, CT3, tw, th, trs, td, 255)
			elseif tri_count == 2 then
				draw_triangle(CV1, CV2, CV3, CT1, CT2, CT3, tw, th, trs, td, 255)
				draw_triangle(CV4, CV5, CV6, CT4, CT5, CT6, tw, th, trs, td, 255)
			end

			-- Triangle two:
			tri_count = clip_triangle(a, d, c, SUV_11, SUV_10, SUV_00)
			if tri_count == 1 then
				draw_triangle(CV1, CV2, CV3, CT1, CT2, CT3, tw, th, trs, td, 255)
			elseif tri_count == 2 then
				draw_triangle(CV1, CV2, CV3, CT1, CT2, CT3, tw, th, trs, td, 255)
				draw_triangle(CV4, CV5, CV6, CT4, CT5, CT6, tw, th, trs, td, 255)
			end
		end
	
		CAMERA_DIRTY = false
	end

	return {
		mesh = MESH;
		texture = TEXTURE;
		object = OBJECT;

		recomputeMeshBounds = RECOMPUTE_MESH_BOUNDS;
		getMeshAABB = GET_MESH_AABB;
		getMeshSB = GET_MESH_SB;

		setObjectMesh = SET_OBJECT_MESH;
		setObjectTexture = SET_OBJECT_TEXTURE;
		setObjectPosition = SET_OBJECT_POSITION;
		setObjectRotation = SET_OBJECT_ROTATION;

		getCameraBasis = GET_CAMERA_BASIS;
		setCameraPosition = SET_CAMERA_POSITION;
		setCameraRotation = SET_CAMERA_ROTATION;
		setFieldOfView = SET_FIELD_OF_VIEW;

		setLightingAmbient = SET_LIGHTING_AMBIENT;
		setLightingDirection = SET_LIGHTING_DIRECTION;
		setSkyboxTextures = SET_SKYBOX_TEXTURES;

		render = RENDER;
		setViewResolution = SET_VIEW_RESOLUTION;
	}
end