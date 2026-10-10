
--[=[
	2d - minimal, performant, platform agnostic 2D renderer in pure Luau.
	* Derived from @AnotherSubatomo/pluto `renderer/standard`.
	Author: @AnotherSubatomo (GitHub)
	SPDX-License-Identifier: MIT
]=]

--[=[
	SUPPLEMENTARY INFORMATION ABOUT THE IMPLEMENTATION
	==================================================

	# Position vectors passed to every renderer function MUST
	be and are ASSUMED to be 0-based, unsigned integers.
	Float coordinates should be floored before passing.

	# Bound checks aren't done during pixel draws to remain as
	performant as possible. Ensure all elements you command
	to draw are within bounds before passing.
]=]

--!strict
--!optimize 2
--!native

-- A bitmap font definition, where the bitmap per glyph must fit in 52 bits or less.
-- The product of the `width` and `height` must also be 52 or less.
-- The bitmap binary literals are grouped by rows: the leftmost group of bits represents
-- the topmost row, and the leftmost bit in that group represents the leftmost pixel.
-- (e.g., in 0b_100_010_001, '100' is the topmost row, then '010', then '001' at the bottom)
-- Because binary literals place the most significant bits on the left, reading bits
-- linearly from LSB to MSB reads from right-to-left and bottom-to-top, placing the
-- origin point at the bottom-right.
export type u52_bitmap_font = {
	width: number,
	height: number,
	padding: number,
	bitmaps: {[number]: number}
}

-- The Atari Portfolio palmtop computer's 6x8 pixel font, as a 5x7 u35-serialized bitmap.
-- * From: https://int10h.org/oldschool-pc-fonts/fontlist/font?portfolio_6x8
-- * 6x8 was able to be reduced to 5x7 because the right and bottom edges were all paddings.
-- * These removed paddings would then be automatically accounted by the font renderer
const PORTFOLIO6x8: u52_bitmap_font = {
	width = 5,
	height = 7,
	padding = 1, --> on the bottom & right edges
	bitmaps = {
		[0x21] = 0b_00100_00100_00100_00100_00100_00000_00100, -- !
		[0x22] = 0b_01010_01010_01010_00000_00000_00000_00000, -- "
		[0x23] = 0b_01010_01010_11111_01010_11111_01010_01010, -- #
		[0x24] = 0b_00100_01111_10000_01110_00001_11110_00100, -- $
		[0x25] = 0b_11000_11001_00010_00100_01000_10011_00011, -- %
		[0x26] = 0b_01100_10010_10100_01000_10101_10010_01101, -- &
		[0x27] = 0b_00110_00010_00100_00000_00000_00000_00000, -- '
		[0x28] = 0b_00010_00100_01000_01000_01000_00100_00010, -- (
		[0x29] = 0b_01000_00100_00010_00010_00010_00100_01000, -- )
		[0x2A] = 0b_00000_00100_10101_01110_10101_00100_00000, -- *
		[0x2B] = 0b_00000_00100_00100_11111_00100_00100_00000, -- +
		[0x2C] = 0b_00000_00000_00000_00000_00110_00010_00100, -- ,
		[0x2D] = 0b_00000_00000_00000_11111_00000_00000_00000, -- -
		[0x2E] = 0b_00000_00000_00000_00000_00000_00110_00110, -- .
		[0x2F] = 0b_00000_00001_00010_00100_01000_10000_00000, -- /

		[0x30] = 0b_01110_10001_10011_10101_11001_10001_01110, -- 0
		[0x31] = 0b_00100_01100_00100_00100_00100_00100_01110, -- 1
		[0x32] = 0b_01110_10001_00001_00010_00100_01000_11111, -- 2
		[0x33] = 0b_11111_00010_00100_00010_00001_10001_01110, -- 3
		[0x34] = 0b_00010_00110_01010_10010_11111_00010_00010, -- 4
		[0x35] = 0b_11111_10000_11110_00001_00001_10001_01110, -- 5
		[0x36] = 0b_00110_01000_10000_11110_10001_10001_01110, -- 6
		[0x37] = 0b_11111_00001_00010_00100_00100_00100_00100, -- 7
		[0x38] = 0b_01110_10001_10001_01110_10001_10001_01110, -- 8
		[0x39] = 0b_01110_10001_10001_01111_00001_00010_01100, -- 9

		[0x3A] = 0b_00000_00110_00110_00000_00110_00110_00000, -- :
		[0x3B] = 0b_00000_00110_00110_00000_00110_00010_00100, -- ;
		[0x3C] = 0b_00001_00010_00100_01000_01000_00100_00010, -- <
		[0x3D] = 0b_00000_00000_11111_00000_11111_00000_00000, -- =
		[0x3E] = 0b_01000_00100_00010_00001_00010_00100_01000, -- >
		[0x3F] = 0b_01110_10001_00001_00010_00100_00000_00100, -- ?
		[0x40] = 0b_01110_10001_10011_10101_10010_10000_01110, -- @

		[0x41] = 0b_01110_10001_10001_10001_11111_10001_10001, -- A
		[0x42] = 0b_11110_10001_10001_11110_10001_10001_11110, -- B
		[0x43] = 0b_01110_10001_10000_10000_10000_10001_01110, -- C
		[0x44] = 0b_11100_10010_10001_10001_10001_10010_11100, -- D
		[0x45] = 0b_11111_10000_10000_11110_10000_10000_11111, -- E
		[0x46] = 0b_11111_10000_10000_11110_10000_10000_10000, -- F
		[0x47] = 0b_01110_10001_10000_10000_10111_10001_01111, -- G
		[0x48] = 0b_10001_10001_10001_11111_10001_10001_10001, -- H
		[0x49] = 0b_01110_00100_00100_00100_00100_00100_01110, -- I
		[0x4A] = 0b_00111_00010_00010_00010_00010_10010_01100, -- J
		[0x4B] = 0b_10001_10010_10100_11000_10100_10010_10001, -- K
		[0x4C] = 0b_11111_10000_10000_10000_10000_10000_11111, -- L
		[0x4D] = 0b_10001_11011_10101_10101_10001_10001_10001, -- M
		[0x4E] = 0b_10001_10001_11001_10101_10011_10001_10001, -- N
		[0x4F] = 0b_01110_10001_10001_10001_10001_10001_01110, -- O
		[0x50] = 0b_11110_10001_10001_11110_10001_10000_10000, -- P
		[0x51] = 0b_01110_10001_10001_10001_10101_10010_01101, -- Q
		[0x52] = 0b_11110_10001_10001_11110_10100_10010_10001, -- R
		[0x53] = 0b_01110_10001_10000_01110_00001_10001_01110, -- S
		[0x54] = 0b_11111_00100_00100_00100_00100_00100_00100, -- T
		[0x55] = 0b_10001_10001_10001_10001_10001_10001_01110, -- U
		[0x56] = 0b_10001_10001_10001_10001_10001_01010_00100, -- V
		[0x57] = 0b_10001_10001_10001_10101_10101_11011_10001, -- W
		[0x58] = 0b_10001_10001_01010_00100_01010_10001_10001, -- X
		[0x59] = 0b_10001_10001_10001_01110_00100_00100_00100, -- Y
		[0x5A] = 0b_11111_00001_00010_00100_01000_10000_11111, -- Z

		[0x5B] = 0b_01110_01000_01000_01000_01000_01000_01110, -- [
		[0x5C] = 0b_00000_10000_01000_00100_00010_00001_00000, -- \
		[0x5D] = 0b_01110_00010_00010_00010_00010_00010_01110, -- ]
		[0x5E] = 0b_00100_01010_10001_00000_00000_00000_00000, -- ^
		[0x5F] = 0b_00000_00000_00000_00000_00000_00000_11111, -- _
		[0x60] = 0b_01100_01000_00100_00000_00000_00000_00000, -- `

		[0x61] = 0b_00000_00000_01110_00001_01111_10001_01111, -- a
		[0x62] = 0b_10000_10000_10110_11001_10001_10001_11110, -- b
		[0x63] = 0b_00000_00000_01110_10000_10000_10001_01110, -- c
		[0x64] = 0b_00001_00001_01101_10011_10001_10001_01111, -- d
		[0x65] = 0b_00000_00000_01110_10001_11111_10000_01111, -- e
		[0x66] = 0b_00110_01001_01000_11110_01000_01000_01000, -- f
		[0x67] = 0b_00000_00000_01111_10001_01111_00001_01110, -- g
		[0x68] = 0b_10000_10000_10110_11001_10001_10001_10001, -- h
		[0x69] = 0b_00100_00000_01100_00100_00100_00100_01110, -- i
		[0x6A] = 0b_00010_00000_00110_00010_00010_10010_01100, -- j
		[0x6B] = 0b_10000_10000_10001_10010_10100_11010_10001, -- k
		[0x6C] = 0b_01100_00100_00100_00100_00100_00100_01110, -- l
		[0x6D] = 0b_00000_00000_11010_10101_10101_10001_10001, -- m
		[0x6E] = 0b_00000_00000_10110_11001_10001_10001_10001, -- n
		[0x6F] = 0b_00000_00000_01110_10001_10001_10001_01110, -- o
		[0x70] = 0b_00000_00000_11110_10001_11110_10000_10000, -- p
		[0x71] = 0b_00000_00000_01111_10001_01111_00001_00001, -- q
		[0x72] = 0b_00000_00000_10110_11001_10000_10000_10000, -- r
		[0x73] = 0b_00000_00000_01111_10000_01110_00001_11110, -- s
		[0x74] = 0b_01000_01000_11110_01000_01000_01001_00110, -- t
		[0x75] = 0b_00000_00000_10001_10001_10001_10011_01101, -- u
		[0x76] = 0b_00000_00000_10001_10001_10001_01010_00100, -- v
		[0x77] = 0b_00000_00000_10001_10001_10101_10101_01010, -- w
		[0x78] = 0b_00000_00000_10001_01010_00100_01010_10001, -- x
		[0x79] = 0b_00000_00000_10001_10001_01111_00001_11110, -- y
		[0x7A] = 0b_00000_00000_11111_00010_00100_01000_11111, -- z

		[0x7B] = 0b_00011_00100_00100_01100_00100_00100_00011, -- {
		[0x7C] = 0b_00100_00100_00100_00000_00100_00100_00100, -- |
		[0x7D] = 0b_11000_00100_00100_00110_00100_00100_11000, -- }
		[0x7E] = 0b_01101_10110_00000_00000_00000_00000_00000, -- ~
	}
}

const iterate_codes = utf8.codes ''

-- Reads the bit state from a bitmap at a given coordinate (0-based).
const function sample_bitmap(bitmap: number, x: number, y: number, row_width: number): (number)
	local offset = y * row_width + x
	if offset > 31 then
		offset -= 32
		bitmap //= 0x100000000
	end
	return bit32.band(bit32.rshift(bitmap, offset), 0b1)
end

-- Draws a simple horizontal line, used by `circle()`, design to be automatically inlined by the compiler.
const function horizontal_line(image: buffer, color: number, left_x: number, right_x: number, offset_y: number): ()
	for offset = offset_y + (left_x * 4), offset_y + (right_x * 4), 4 do
		buffer.writeu32(image, offset, color)
	end
end

return function (_image: buffer, max_resolution: vector, view_resolution: vector?)
	const IMAGE_MEMSIZE = max_resolution.x * max_resolution.y * 4
	if buffer.len(_image) ~= IMAGE_MEMSIZE then
		error "The given image buffer's size must be equal to the product of the given maximum resolution's `x` and `y` times 4."
	end

	const IMAGE = _image
	local VIEW_RESOLUTION = view_resolution or max_resolution
	local VIEW_WIDTH = VIEW_RESOLUTION.x
	local VIEW_HEIGHT = VIEW_RESOLUTION.y
	local VIEW_STRIDE = VIEW_WIDTH * 4

	local CHAR_WIDTH = PORTFOLIO6x8.width
	local CHAR_HEIGHT = PORTFOLIO6x8.height
	local CHAR_PADDING = PORTFOLIO6x8.padding

	local STYLE_COLOR = 0xFF000000
	local STYLE_TEXT_FONT = PORTFOLIO6x8

	const function GET_TEXT_SIZE(text: string): (number, number)
		const text_length = utf8.len(text) or 1
		return CHAR_WIDTH * text_length + CHAR_PADDING * (text_length - 1), CHAR_HEIGHT
	end

	-- Sets the global color to be used by shape renderers.
	const function SET_COLOR(color: number): ()
		STYLE_COLOR = color
	end

	-- Sets the global font to be used by text renderers. Returns a success value.
	const function SET_FONT(font: u52_bitmap_font?): ()
		if font and font.width * font.height > 52 then
			error "Cannot set the font to the given, the product of its width and height was greater than 52."
		end
		STYLE_TEXT_FONT = font or PORTFOLIO6x8
	end

	-- Sets the global text size to be used by text renderers.
	const function SET_TEXT_SIZE(text_size: number): ()
		const font = STYLE_TEXT_FONT
		const font_width = font.width
		const font_height = font.height

		CHAR_WIDTH = ((font_width / font_height) * text_size + 0.5) // 1
		CHAR_HEIGHT = text_size
		CHAR_PADDING = ((font.padding / font_height) * text_size + 0.5) // 1
	end

	-- Draws a line.
	-- * Thickness is axis-aligned, not perfectly perpendicular, looks slightly "boxy" at steep angles.
	const function LINE(points: {vector}, thickness: number, dash_size: number, gap_size: number): ()
		if thickness == 0 or dash_size == 0 then return end

		const pattern_size = dash_size + gap_size
		local pattern_pos = 0

		for i = 1, #points - 1 do
			const a = points[i]
			const b = points[i + 1]

			local x0 = a.x // 1
			local y0 = a.y // 1
			const x1 = b.x // 1
			const y1 = b.y // 1

			const dx = math.abs(x1 - x0)
			const dy = math.abs(y1 - y0)

			const sx = (x0 < x1) and 1 or -1
			const sy = (y0 < y1) and 1 or -1

			local err = dx - dy
			const half = thickness // 2

			-- Decide major axis once
			const horizontal_major = dx >= dy

			while true do
				-- dash check
				if pattern_pos < dash_size then
					if horizontal_major then
						-- vertical thickness (column span)
						const x = x0
						const y_start = y0 - half
						const y_end = y0 + half

						local offset = y_start * VIEW_STRIDE + x * 4
						for y = y_start, y_end do
							buffer.writeu32(IMAGE, offset, STYLE_COLOR)
							offset += VIEW_STRIDE
						end
					else
						-- horizontal thickness (row span)
						const y = y0
						const x_start = x0 - half
						const x_end = x0 + half

						local offset = y * VIEW_STRIDE + x_start * 4
						for x = x_start, x_end do
							buffer.writeu32(IMAGE, offset, STYLE_COLOR)
							offset += 4
						end
					end
				end

				pattern_pos += 1
				if pattern_pos >= pattern_size then
					pattern_pos = 0
				end

				if x0 == x1 and y0 == y1 then break end

				const e2 = err + err

				if e2 > -dy then
					err -= dy
					x0 += sx
				end

				if e2 < dx then
					err += dx
					y0 += sy
				end
			end
		end
	end

	-- Renders a triangle performantly (derived from `AnotherSubatomo/kosmos`, `draw_triangle()`).
	const function TRIANGLE(a: vector, b: vector, c: vector): ()
		const canvas_bound_x = VIEW_WIDTH - 1
		const canvas_bound_y = VIEW_HEIGHT - 1

		-- Unpack vertices
		local ax, ay = a.x, a.y
		local bx, by = b.x, b.y
		local cx, cy = c.x, c.y

		-- Sort vertices (along with their UV) by ascending Y [c (bottom) -> b -> a (top)]
		if ay > by then ax, ay, bx, by = bx, by, ax, ay end
		if ay > cy then ax, ay, cx, cy = cx, cy, ax, ay end
		if by > cy then bx, by, cx, cy = cx, cy, bx, by end

		-- Precompute vertical distances for interpolation along triangle edges
		const dy_ab = by - ay
		const dy_ac = cy - ay
		const dy_bc = cy - by

		-- Calculate edge slopes for incremental interpolation
		const m_ab = if dy_ab ~= 0 then (bx - ax) / dy_ab else 0
		const m_ac = if dy_ac ~= 0 then (cx - ax) / dy_ac else 0
		const m_bc = if dy_bc ~= 0 then (cx - bx) / dy_bc else 0

		-- Discretize to get scan bounds
		local y_start = ay // 1
		local y_end   = cy // 1

		-- Ensure correct ordering after discretization
		if y_start > y_end then y_start, y_end = y_end, y_start end

		-- Clamp to viewport height (prevents OOB buffer errors)
		y_start = math.max(0, y_start)
		y_end   = math.min(canvas_bound_y, y_end)

		-- Split the triangle!
		local y_middle = by // 1

		-- Clamp to scan bounds
		if y_middle < y_start then y_middle = y_start end
		if y_middle > y_end   then y_middle = y_end   end

		-- Precompute row offset into image buffer
		local write_offset = y_start * VIEW_STRIDE

		-- Rasterize the top half of triangle (a --> b)
		for y = y_start, y_middle - 1 do
			-- Compute the general blend factor
			const lt = (y - ay)
			const rt = (y - ay)

			-- Compute left/right X positions of the scanline
			local lx = ax + lt * m_ab
			local rx = ax + rt * m_ac

			-- Ensure left-to-right ordering
			if lx > rx then lx, rx = rx, lx end

			-- Clamp horizontal span to screen bounds
			const x_start = math.max(0, (lx + 0.5) // 1)
			const x_end   = math.min(canvas_bound_x, rx // 1)
			local offset  = write_offset + x_start * 4

			-- Fill pixels across scanline
			for _ = x_start, x_end do
				buffer.writeu32(IMAGE, offset, STYLE_COLOR)
				offset += 4
			end

			write_offset += VIEW_STRIDE
		end

		-- Adjust the split if discretization misses the true middle scanline
		const y_middle_adj = y_middle + (y_middle < by and 1 or 0)

		-- Rasterize bottom half of triangle (b --> c)
		for y = y_middle_adj, y_end do
			-- Compute the general blend factor
			const lt = (y - by)
			const rt = (y - ay)

			-- Compute left/right X positions of the scanline
			local lx = bx + lt * m_bc
			local rx = ax + rt * m_ac

			-- Ensure left-to-right ordering
			if lx > rx then lx, rx = rx, lx end

			-- Clamp horizontal span to screen bounds
			const x_start = math.max(0, (lx + 0.5) // 1)
			const x_end   = math.min(canvas_bound_x, rx // 1)
			local offset  = write_offset + x_start * 4

			-- Fill pixels across scanline
			for _ = x_start, x_end do
				buffer.writeu32(IMAGE, offset, STYLE_COLOR)
				offset += 4
			end

			write_offset += VIEW_STRIDE
		end
	end

	-- Renders a simple rectangle performantly.
	const function RECTANGLE(position: vector, size: vector): ()
		const size_x_stride = size.x * 4

		const init_offset = position.y * VIEW_STRIDE + position.x * 4

		for offset_x = 0, size_x_stride - 4, 4 do
			buffer.writeu32(IMAGE, init_offset + offset_x, STYLE_COLOR)
		end

		local write_offset = init_offset + VIEW_STRIDE

		for i = 1, size.y - 1 do
			buffer.copy(IMAGE, write_offset, IMAGE, init_offset, size_x_stride)
			write_offset += VIEW_STRIDE
		end
	end

	-- Renders a circle via the midpoint circle algorithm (i.e. Bresenham's circle).
	const function CIRCLE(position: vector, radius: number): ()

		const cx, cy = position.x, position.y
		local x, y = radius, 0
		local d = 1 - radius

		while x >= y do
			const cx_x = cx + x
			const cx_y = cx + y
			const cx_nx = cx - x
			const cx_ny = cx - y

			horizontal_line(IMAGE, STYLE_COLOR, cx_nx, cx_x, (cy + y) * VIEW_STRIDE)
			horizontal_line(IMAGE, STYLE_COLOR, cx_nx, cx_x, (cy - y) * VIEW_STRIDE)
			horizontal_line(IMAGE, STYLE_COLOR, cx_ny, cx_y, (cy + x) * VIEW_STRIDE)
			horizontal_line(IMAGE, STYLE_COLOR, cx_ny, cx_y, (cy - x) * VIEW_STRIDE)

			y += 1

			if d < 0 then
				d += 2 * y + 1
			else
				x -= 1
				d += 2 * (y - x) + 1
			end
		end
	end

	-- Renders text for bitmap fonts; newlines are not properly supported.
	const function TEXT(position: vector, text: string): ()
		const bitmaps = STYLE_TEXT_FONT.bitmaps
		const font_width = STYLE_TEXT_FONT.width
		const font_height = STYLE_TEXT_FONT.height

		const char_bound_x = CHAR_WIDTH - 1
		const char_bound_y = CHAR_HEIGHT - 1
		const u_ratio = (1 / char_bound_x) * (font_width - 1)
		const v_ratio = (1 / char_bound_y) * (font_height - 1)

		local init_write_offset = position.y * VIEW_STRIDE + position.x * 4
		const color_rgb = bit32.band(STYLE_COLOR, 0x00FFFFFF)

		local this_offset, this_code = iterate_codes(text, 0)
		while this_code do
			const bitmap = bitmaps[this_code] or 0
			local write_offset = init_write_offset

			for y = char_bound_y, 0, -1 do
				const v = y * v_ratio
				const lv = v // 1
				const hv = (v + 0.5) // 1
				const tv = v - lv

				for x = char_bound_x, 0, -1 do
					const u = x * u_ratio
					const lu = u // 1
					const hu = (u + 0.5) // 1
					const tu = u - lu

					const p00 = sample_bitmap(bitmap, lu, lv, font_width)
					local final_color = 0

					if tu == 0 and tv == 0 then
						-- Exact sample, no interpolation needed
						final_color = p00 == 1 and STYLE_COLOR or 0
					else
						-- Bilinear sampling
						const p10 = sample_bitmap(bitmap, hu, lv, font_width)
						const p01 = sample_bitmap(bitmap, lu, hv, font_width)
						const p11 = sample_bitmap(bitmap, hu, hv, font_width)

						const a = p00 + (p10 - p00) * tu
						const b = p01 + (p11 - p01) * tu
						local value = a + (b - a) * tv

						-- Gamma correction (before sharpening)
						value = math.sqrt(value)

						-- Adaptive sharpening (only in midtones)
						if value > 0.3 and value < 0.7 then
							value = math.clamp((value - 0.5) * 1.2 + 0.5, 0, 1)
						end

						-- Back to linear, then to u8
						value = (value * value) * 255 // 1

						final_color = value == 0 and 0 or (value * 0x1000000 + color_rgb)
					end

					if final_color ~= 0 then
						const offset_x = (char_bound_x - x) * 4
						buffer.writeu32(IMAGE, write_offset + offset_x, final_color)
					end
				end

				write_offset += VIEW_STRIDE
			end

			init_write_offset += (CHAR_WIDTH + CHAR_PADDING) * 4
			this_offset, this_code = iterate_codes(text, this_offset)
		end
	end

	return {
		getTextSize = GET_TEXT_SIZE,

		setColor = SET_COLOR,
		setFont = SET_FONT,
		setTextSize = SET_TEXT_SIZE,

		line = LINE,
		triangle = TRIANGLE,
		rectangle = RECTANGLE,
		circle = CIRCLE,
		text = TEXT,
	}
end