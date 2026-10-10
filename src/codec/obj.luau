
-- Quick and dirty .OBJ parser and de-indexer for Luau
-- SPDX-License-Identifier: CC0-1.0

--!strict
--!optimize 2
--!native

const NAN = 0/0 -- to represent `nil` in vectors
const match = string.match
const talloc = table.create
const tclear = table.clear
const make_vec = vector.create
const iter_codes = utf8.codes ''

-- Returns a number that is the binary concatenation of three u16 numbers that represent indices.
const function make_index_tuple(ai: number, bi: number, ci: number): (number)
	return ai + bi * 0x10000 + ci * 0x100000000
end

-- Tries to return a number as much as possible.
const function number(str: string?): (number)
	return tonumber(str) or NAN
end

-- Returns 0 (for "no index") or a non-zero, positive integer as an index.
const function parse_index(i: string?, len: number): (number)
	local idx = tonumber(i)
	if not idx then return 0 end
	if idx < 0 then idx = len + idx + 1 end
	if idx < 1 or idx > len then return 0 end
	return idx
end

export type vectors = {vector} -- dense array
-- opinionated representation of an OBJ file
export type LuauOBJ = {
	vertices: vectors,
	uvs: vectors,
	normals: vectors,
	faces: vectors
}

-- OBJ parser entry point.
const function load_OBJ(source: string): (LuauOBJ)
	local total_faces = 0
	local total_vertices = 0
	local total_uvs_listed = 0
	local total_normals_listed = 0

	local curr_offset, curr_code = iter_codes(source, 0)

	while curr_code do
		const next_offset, next_code = iter_codes(source, curr_offset)
		if curr_code == 118 then
			if next_code == 32 then
				total_vertices += 1
			elseif next_code == 116 then
				total_uvs_listed += 1
			elseif next_code == 110 then
				total_normals_listed += 1
			end
		elseif curr_code == 102 and next_code == 32 then
			total_faces += 1
		end
		curr_offset, curr_code = next_offset, next_code
	end

	-- This limit exist because indices for `make_index_tuple()` are expected
	-- to be of size `u16`; but beyond that, I also think that vertex counts
	-- greater than 65535 is just too much to ask for.
	if total_vertices > 0xFFFF then
		error "OBJ file's vertice count is greater than what is tolerable for the decoder."
	end

	const faces = talloc(total_faces) :: vectors
	const vertices = talloc(total_vertices) :: vectors
	const uvs = talloc(total_vertices) :: vectors
	const normals = talloc(total_vertices) :: vectors

	const vertex_list = talloc(total_vertices) :: vectors
	const uv_list = talloc(total_uvs_listed) :: vectors
	const normal_list = talloc(total_normals_listed) :: vectors

	local n_faces = 0
	local n_unique_vertices = 0

	local n_vertices = 0
	local n_uvs = 0
	local n_normals = 0

	--> Yes, the vector datatype actually has stable hashing semantics for all correct Luau runtimes!
	const point_lookup: {[number]: number} = {}
	const index_tuples = talloc(3) :: {number}
	
	const function get_vertex_index(index_tuple: number): (number)
		const existing_idx = point_lookup[index_tuple]
		if existing_idx then return existing_idx end

		n_unique_vertices += 1
		const idx = n_unique_vertices
		point_lookup[index_tuple] = idx

		vertices[idx] = vertex_list[bit32.band(index_tuple, 0xFFFF)]
		uvs[idx] = uv_list[bit32.band(index_tuple / 0x10000, 0xFFFF)]
		normals[idx] = normal_list[bit32.band(index_tuple / 0x100000000, 0xFFFF)]

		return idx
	end

	for line in string.gmatch(source, "([^\r\n]+)") do
		const prefix, body = match(line, "^(%S+)%s*(.*)")
		if not body then continue end

		if prefix == "v" then
			n_vertices += 1
			const x, y, z = match(body, "([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
			vertex_list[n_vertices] = make_vec(number(x), number(y), tonumber(z))

		elseif prefix == "vt" then
			n_uvs += 1
			const u, v = match(body, "([%-%d%.eE]+)%s+([%-%d%.eE]+)")
			uv_list[n_uvs] = make_vec(number(u), tonumber(v) or 0)

		elseif prefix == "vn" then
			n_normals += 1
			const x, y, z = match(body, "([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
			normal_list[n_normals] = make_vec(number(x), number(y), tonumber(z))

		elseif prefix == "f" then
			local n_index_tuples = 0
			tclear(index_tuples)

			for index_tuple in string.gmatch(body, "%S+") do
				-- formats: v; v/vt; v//vn; v/vt/vn
				const a, b, c = match(index_tuple, "([^/]*)/?([^/]*)/?([^/]*)")
				n_index_tuples += 1
				index_tuples[n_index_tuples] = make_index_tuple(
					parse_index(a, n_vertices),
					parse_index(b, n_uvs),
					parse_index(c, n_normals)
				)
			end

			-- Fan triangulation: 1,2,3 / 1,3,4 / ...
			for i = 2, n_index_tuples - 1 do
				const i_1 = i + 1
				const pa, pb, pc = index_tuples[1], index_tuples[i], index_tuples[i_1]

				const a = get_vertex_index(pa)
				const b = get_vertex_index(pb)
				const c = get_vertex_index(pc)

				n_faces += 1
				faces[n_faces] = make_vec(a, b, c)
			end
		end
	end

	return { vertices = vertices, uvs = uvs, normals = normals, faces = faces }
end

return load_OBJ