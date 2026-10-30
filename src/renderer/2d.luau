
--[=[
	2d - minimal, performant, platform agnostic 2D renderer in pure Luau.
	* Derived from @AnotherSubatomo/pluto `renderer/standard`.
	Author: @AnotherSubatomo (GitHub)
	SPDX-License-Identifier: MIT
]=]

--[=[
	INVARIANTS & DESIGN NOTES
	=========================

	The following are assumptions the implementation makes, or
	behaviors callers must know about. They are not enforced by
	type checks and will fail silently (or corrupt output) if
	violated.

	# Buffer contracts
	------------------
	* `image` and `W` MUST have identical lengths, equal to
	  `max_resolution.x * max_resolution.y * 4`.

	* `W` is a per-pixel depth buffer of f32 bit patterns.
	   Every filled pixel receives `F32_INF` (`0x7F800000`).
	   The renderer never READS `W`; it is produced for `renderer/3d`.

	* The `(x, y)` coordinate space is `RENDER_RESOLUTION`, and
	  rows are tightly packed at a stride of `RENDER_WIDTH * 4`,
	  NOT `max_resolution.x * 4`. When
	  `render_resolution != max_resolution`, the buffer is only
	  partially utilized and the packing is tighter than the
	  allocation implies. Any consumer writing the buffer to an
	  image (e.g. `editableImage:writePixelsBuffer`) must use
	  `RENDER_WIDTH` as the row stride.

	# View / resolution
	-------------------
	* `render_resolution` defaults to `max_resolution` when
	  omitted from the constructor.

	* The constructor does NOT validate `render_resolution`
	  against `max_resolution`; `SET_RENDER_RESOLUTION` does.
	  Passing a larger `render_resolution` to the constructor
	  will produce out-of-bounds writes.

	* `SET_RENDER_RESOLUTION` only works when there is nothing
	  on the clip stack; this is done to make reasoning easier.

	# Coordinates
	-------------
	* All coordinates passed to primitive renderers are assumed
	  to be 0-based integers. `LINE`, `CIRCLE`, and `TEXT`
	  effectively floor via span math / clip checks. `RECTANGLE`
	  is the exception: it does NOT floor `px, py, sx, sy`.
	  Floor them yourself before calling.

	* `LINE` accepts a flat `{x1, y1, x2, y2, ...}` polyline.
	  An odd trailing element is silently ignored. Fewer than
	  two points is a no-op.

	* `CIRCLE` is an UNFILLED outline (Bresenham). `radius`
	  must be a non-negative integer; negative radii are a
	  no-op.

	* Line thickness is applied perpendicular to the segment
	  and rounded via `// 1` on each span edge. A line and a
	  rectangle of the same nominal thickness will not have
	  identical pixel counts. `RECTANGLE` uses inclusive
	  `y + sy - 1`; spans do not add a `+1`.

	# Clipping
	----------
	* `PUSH_CLIP(x, y, w, h)` intersects the given rect with
	  the current clip (and floors its inputs). Nested pushes
	  are supported.

	* `GET_CLIP_POSITION()` returns the effective (intersected)
	  clip origin, not the origin of the most recent push.

	* `CLIP_X_MIN`/`CLIP_Y_MIN` are always >= 0 by construction
	  (they are initialized to 0 and only raised via `max`),
	  so fast-path offset math in `TEXT` is safe from negative
	  byte offsets.

	* The clip is independent of `RENDER_RESOLUTION`. Text and
	  shapes are clipped to the active clip rect, not to the
	  view; `getTextBounds` may exceed the view.

	# Fonts & text
	--------------
	* `SET_TEXT_SIZE(size)` derives `CHAR_WIDTH` and
	  `CHAR_PADDING` from font metrics using round-to-nearest
	  (`+ 0.5 // 1`):
	      CHAR_WIDTH   = round(font.width   / font.height * size)
	      CHAR_HEIGHT  = size
	      CHAR_PADDING = round(font.padding / font.height * size)
	  Changing the font and re-setting the same logical size
	  can yield a different pixel width/padding.

	* `CHAR_WIDTH` can round to 0 for tiny sizes or narrow
	  fonts. There is no guard against this; `TEXT` and
	  `GET_TEXT_BOUNDS` will degenerate. Keep
	  `size >= font.height / font.width` (roughly) to avoid it.

	* `SET_FONT(nil)` clears the glyph cache but KEEPS the
	  current font. It does not reset to the default font.

	* The glyph cache is keyed by codepoint and cleared on
	  `SET_FONT` and `SET_TEXT_SIZE`. It is intentionally NOT
	  cleared on `SET_RENDER_RESOLUTION` (glyphs are
	  resolution-independent). Preserve this when editing.

	* `GET_TEXT_BOUNDS` reflects the CURRENT font and text
	  size; call `SET_FONT` / `SET_TEXT_SIZE` first. The
	  returned width excludes trailing `CHAR_PADDING`; the
	  returned height is `CHAR_HEIGHT * lines` with no
	  trailing padding, and counts a line for each `\n` plus
	  one for the final segment. A string of only `\r`
	  reports one line of height 0 width, even though `TEXT`
	  draws and advances nothing for it.

	* `SET_FONT` returns a boolean that is always `true` on
	  the success path (the post-assignment comparison can
	  only be false when `font == nil` and the previous font
	  was nil, which is impossible). Treat the return as
	  reserved.

	# Bitmap fonts (u52_bitmap_font)
	-------------------------------
	* `width * height` must be <= 52. `SET_FONT` enforces this
	  product, but does NOT validate individual `bitmaps`
	  values. Bit-packing assumes each value is < 2^52 (Luau
	  doubles cannot represent 2^52 + 1 exactly, and
	  `sample_bitmap` splits at bit 31 via division by
	  2^32). Pass well-formed bitmaps.

	* Bit-packing convention: rows are grouped left-to-right
	  with the topmost row's bits in the most-significant
	  group; within a row, the leftmost bit is the leftmost
	  pixel. Reading bits linearly from LSB to MSB therefore
	  proceeds right-to-left and bottom-to-top, placing the
	  origin at the bottom-right.

	* `padding` is on the right and bottom edges and is NOT
	  baked into the bitmap; the text renderer accounts for it
	  via `CHAR_PADDING`.
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
		[0x50] = 0b_11110_10001_10001_11110_10000_10000_10000, -- P
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

const F32_INF = 0x7F800000 -- IEEE 754's bit patterns for f32's positive infinity

const max = math.max
const min = math.min
const abs = math.abs

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

return function (image: buffer, w: buffer, max_resolution: vector, render_resolution: vector?)
	const IMAGE_MEMSIZE = max_resolution.x * max_resolution.y * 4
	if buffer.len(image) ~= IMAGE_MEMSIZE or buffer.len(w) ~= IMAGE_MEMSIZE then
		error "The given image buffer's size must be equal to the product of the given maximum resolution's `x` and `y` times 4."
	end

	const IMAGE = image
	const W = w

	-- View settings
	local RENDER_RESOLUTION = render_resolution or max_resolution
	local RENDER_WIDTH = RENDER_RESOLUTION.x
	local RENDER_HEIGHT = RENDER_RESOLUTION.y
	local ROW_STRIDE = RENDER_WIDTH * 4

	-- Style settings
	local STYLE_COLOR = 0xFF000000 -- 0xAABBGGRR
	local STYLE_THICKNESS = 1
	local STYLE_TEXT_FONT = PORTFOLIO6x8

	-- Font settings
	local CHAR_WIDTH = STYLE_TEXT_FONT.width
	local CHAR_HEIGHT = STYLE_TEXT_FONT.height
	local CHAR_PADDING = STYLE_TEXT_FONT.padding

	-- Glyph blend cache: codepoint -> buffer of CHAR_WIDTH * CHAR_HEIGHT u8 alphas.
	-- Invalidated whenever the font or text size changes.
	local GLYPH_CACHE: {[number]: buffer} = {}

	-- Clip settings
	local CLIP_X_MIN = 0
	local CLIP_Y_MIN = 0
	local CLIP_X_MAX = RENDER_WIDTH - 1
	local CLIP_Y_MAX = RENDER_HEIGHT - 1

	local CLIP_STACK = {}
	local CLIP_STACK_N = 0

	-- Draws a vertical span at column x, covering rows `start_y` through `end_y` inclusive.
	const function draw_vertical_span(x: number, start_y: number, end_y: number): ()
		if x < CLIP_X_MIN or x > CLIP_X_MAX then return end
		if start_y < CLIP_Y_MIN then start_y = CLIP_Y_MIN end
		if end_y > CLIP_Y_MAX then end_y = CLIP_Y_MAX end
		if start_y > end_y then return end

		const x_byte = x * 4
		local offset = start_y * ROW_STRIDE + x_byte
		for _ = start_y, end_y do
			buffer.writeu32(IMAGE, offset, STYLE_COLOR)
			buffer.writeu32(W, offset, F32_INF)
			offset += ROW_STRIDE
		end
	end

	-- Draws a horizontal span at row y, covering columns `left_x` through `right_x` inclusive.
	const function draw_horizontal_span(y: number, left_x: number, right_x: number): ()
		if y < CLIP_Y_MIN or y > CLIP_Y_MAX then return end
		if left_x < CLIP_X_MIN then left_x = CLIP_X_MIN end
		if right_x > CLIP_X_MAX then right_x = CLIP_X_MAX end
		if left_x > right_x then return end

		const row_offset = y * ROW_STRIDE
		const start_offset = row_offset + left_x * 4
		const end_offset   = row_offset + right_x * 4
		for offset = start_offset, end_offset, 4 do
			buffer.writeu32(IMAGE, offset, STYLE_COLOR)
			buffer.writeu32(W, offset, F32_INF)
		end
	end

	-- Rasterizes a glyph to a u8 blend mask using pseudo-bilinear filtering of the
	-- binary source bitmap. The cost of this is paid once per (codepoint, size) pair.
	const function rasterize_glyph(codepoint: number): (buffer)
		const font_width = STYLE_TEXT_FONT.width
		const font_height = STYLE_TEXT_FONT.height
		const bitmap = STYLE_TEXT_FONT.bitmaps[codepoint] or 0
		const out = buffer.create(CHAR_WIDTH * CHAR_HEIGHT)

		-- Fast path: output resolution matches source, so every output pixel
		-- is exactly one source pixel. No filtering required.
		if CHAR_WIDTH == font_width and CHAR_HEIGHT == font_height then
			local offset = 0
			for y = font_height - 1, 0, -1 do
				for x = font_width - 1, 0, -1 do
					buffer.writeu8(out, offset, sample_bitmap(bitmap, x, y, font_width) * 255)
					offset += 1
				end
			end
			return out
		end

		const char_bound_x = CHAR_WIDTH - 1
		const char_bound_y = CHAR_HEIGHT - 1
		const u_ratio = if char_bound_x > 0 then (font_width - 1) / char_bound_x else 0
		const v_ratio = if char_bound_y > 0 then (font_height - 1) / char_bound_y else 0

		-- Faked, optimized, bilinear sampling
		local offset = 0
		for py = char_bound_y, 0, -1 do
			const v = py * v_ratio
			const lv = v // 1
			const hv = (v + 0.5) // 1
			const tv = v - lv

			for px = char_bound_x, 0, -1 do
				const u = px * u_ratio
				const lu = u // 1
				const hu = (u + 0.5) // 1
				const tu = u - lu

				const p00 = sample_bitmap(bitmap, lu, lv, font_width)
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
				if value > 255 then value = 255 end

				buffer.writeu8(out, offset, value)
				offset += 1
			end
		end
		return out
	end

	const function GET_RENDER_RESOLUTION(): (vector)
		return vector.create(RENDER_WIDTH, RENDER_HEIGHT)
	end

	const function SET_RENDER_RESOLUTION(render_resolution: vector): ()
		const render_width = render_resolution.x
		const render_height = render_resolution.y

		if CLIP_STACK_N ~= 0 then
			error "Cannot change the render resolution while a clip is active; pop all clips first."
		end

		if render_width < 0 or render_height < 0 then
			error "Invalid view resolution"
		end
		if render_width > max_resolution.x then
			error "New view width cannot be greater than the max width"
		end
		if render_height > max_resolution.y then
			error "New view height cannot be greater than the max height"
		end

		RENDER_RESOLUTION = render_resolution
		RENDER_WIDTH = render_width
		RENDER_HEIGHT = render_height
		ROW_STRIDE = RENDER_WIDTH * 4

		CLIP_X_MIN = 0
		CLIP_Y_MIN = 0
		CLIP_X_MAX = RENDER_WIDTH - 1
		CLIP_Y_MAX = RENDER_HEIGHT - 1
	end

	-- Calculates the bounding box of the text.
	local function GET_TEXT_BOUNDS(text: string): (number, number)
		local curr_line_width = 0
		local max_line_width = 0
		local lines = 1
		
		-- Fast path for empty strings
		if #text == 0 then
			return 0, 0
		end

		for _, codepoint in utf8.codes(text) do
			if codepoint == 10 then -- '\n' character
				max_line_width = if curr_line_width > max_line_width then curr_line_width else max_line_width
				curr_line_width = 0
				lines += 1
			elseif codepoint ~= 13 then -- Ignore '\r' carriage returns for safety
				curr_line_width += 1
			end
		end
		
		-- Evaluate the final line if the string didn't end in a newline
		max_line_width = if curr_line_width > max_line_width then curr_line_width else max_line_width

		return (CHAR_WIDTH + CHAR_PADDING) * max_line_width - CHAR_PADDING, CHAR_HEIGHT * lines
	end

	-- Sets the global color to be used by shape renderers.
	const function SET_COLOR(color: number): ()
		STYLE_COLOR = color
	end

	-- Sets the global font to be used by text renderers. Returns a success value.
	const function SET_FONT(font: u52_bitmap_font?): (boolean)
		if font and font.width * font.height > 52 then
			error "Cannot set the font to the given, the product of its width and height was greater than 52."
		end

		STYLE_TEXT_FONT = font or STYLE_TEXT_FONT
		table.clear(GLYPH_CACHE)

		return STYLE_TEXT_FONT == font
	end

	-- Sets the global text size to be used by text renderers.
	const function SET_TEXT_SIZE(text_size: number): ()
		const font = STYLE_TEXT_FONT
		const font_width = font.width
		const font_height = font.height

		CHAR_WIDTH = ((font_width / font_height) * text_size + 0.5) // 1
		CHAR_HEIGHT = text_size
		CHAR_PADDING = ((font.padding / font_height) * text_size + 0.5) // 1
		table.clear(GLYPH_CACHE)
	end

	const function SET_LINE_THICKNESS(line_thickness: number): ()
		STYLE_THICKNESS = line_thickness
	end

	-- Pushes the clip configuration onto the clip stack such that
	-- the new clip is the intersection of the previous with the given.
	const function PUSH_CLIP(x: number, y: number, w: number, h: number): ()
		CLIP_STACK_N += 1
		CLIP_STACK[CLIP_STACK_N] = {CLIP_X_MIN, CLIP_Y_MIN, CLIP_X_MAX, CLIP_Y_MAX}
		CLIP_X_MIN = max(CLIP_X_MIN, x // 1)
		CLIP_Y_MIN = max(CLIP_Y_MIN, y // 1)
		CLIP_X_MAX = min(CLIP_X_MAX, (x + w) // 1 - 1)
		CLIP_Y_MAX = min(CLIP_Y_MAX, (y + h) // 1 - 1)
	end

	-- Restores the preceeding clip configuration.
	const function POP_CLIP(): ()
		if CLIP_STACK_N == 0 then return end
		const saved = CLIP_STACK[CLIP_STACK_N]
		CLIP_STACK[CLIP_STACK_N] = nil
		CLIP_STACK_N -= 1
		CLIP_X_MIN, CLIP_Y_MIN, CLIP_X_MAX, CLIP_Y_MAX = saved[1], saved[2], saved[3], saved[4]
	end

	-- Returns the current clip's position.
	const function GET_CLIP_POSITION(): (number, number)
		return CLIP_X_MIN, CLIP_Y_MIN
	end

	-- Calculates the bounding box of the current clip.
	const function GET_CLIP_BOUNDS(): (number, number)
		return CLIP_X_MAX - CLIP_X_MIN + 1, CLIP_Y_MAX - CLIP_Y_MIN + 1
	end

	-- Draws a polyline from the given sequence of number pairs (x, y).
	const function LINE(points: {number}): ()
		if STYLE_THICKNESS <= 0 then return end

		for i = 1, #points - 2, 2 do
			const x1, y1 = points[i], points[i + 1]
			const x2, y2 = points[i + 2], points[i + 3]

			const dx = x2 - x1
			const dy = y2 - y1

			if dx == 0 and dy == 0 then
				continue
			elseif dx == 0 then
				-- Pure vertical segment.
				const y_start = min(y1, y2)
				const y_end   = max(y1, y2)
				const x_start = x1 - (STYLE_THICKNESS - 1) // 2
				const x_end   = x_start + STYLE_THICKNESS - 1
				for y = y_start, y_end do
					draw_horizontal_span(y, x_start, x_end)
				end
			elseif dy == 0 then
				-- Pure horizontal segment.
				const x_start = min(x1, x2)
				const x_end   = max(x1, x2)
				const y_start = y1 - (STYLE_THICKNESS - 1) // 2
				const y_end   = y_start + STYLE_THICKNESS - 1
				for x = x_start, x_end do
					draw_vertical_span(x, y_start, y_end)
				end
			else
				const len = math.sqrt(dx * dx + dy * dy)

				if abs(dx) >= abs(dy) then
					-- Shallow: one vertical span per integer x.
					const x_start = min(x1, x2)
					const x_end   = max(x1, x2)
					-- Half-width of the line in the *vertical* direction,
					-- rounded so that integer thickness yields integer spans.
					const span = (STYLE_THICKNESS - 1) / 2 * abs(dy / len)
					const half = span + 0.5
					for x = x_start, x_end do
						const t = (x - x1) / dx
						const cy = y1 + t * dy
						draw_vertical_span(x, (cy - half) // 1, (cy + half) // 1)
					end
				else
					-- Steep: one horizontal span per integer y.
					const y_start = min(y1, y2)
					const y_end   = max(y1, y2)
					const span = (STYLE_THICKNESS - 1) / 2 * abs(dx / len)
					const half = span + 0.5
					for y = y_start, y_end do
						const t = (y - y1) / dy
						const cx = x1 + t * dx
						draw_horizontal_span(y, (cx - half) // 1, (cx + half) // 1)
					end
				end
			end
		end
	end

	-- Renders a simple rectangle performantly.
	const function RECTANGLE(px: number, py: number, sx: number, sy: number): ()
		local x1 = max(px, CLIP_X_MIN)
		local y1 = max(py, CLIP_Y_MIN)
		local x2 = min(px + sx - 1, CLIP_X_MAX)
		local y2 = min(py + sy - 1, CLIP_Y_MAX)
		if x1 > x2 or y1 > y2 then return end

		px, py = x1, y1
		sx = x2 - x1 + 1
		sy = y2 - y1 + 1

		const size_x_stride = sx * 4

		const init_offset = py * ROW_STRIDE + px * 4

		for offset_x = 0, size_x_stride - 4, 4 do
			buffer.writeu32(IMAGE, init_offset + offset_x, STYLE_COLOR)
			buffer.writeu32(W, init_offset + offset_x, F32_INF)
		end

		local write_offset = init_offset + ROW_STRIDE

		for i = 1, sy - 1 do
			buffer.copy(IMAGE, write_offset, IMAGE, init_offset, size_x_stride)
			buffer.copy(W, write_offset, W, init_offset, size_x_stride)
			write_offset += ROW_STRIDE
		end
	end

	-- Renders text for bitmap fonts. Supports '\n' and skips '\r'.
	-- Blends each glyph pixel source-over the existing image using the glyph's
	-- 8-bit alpha as coverage. Existing destination alpha is respected.
	const function TEXT(px: number, py: number, text: string): ()
		-- Pre-extract source channels once per call.
		const src_a = bit32.extract(STYLE_COLOR, 24, 8)
		const src_r = bit32.extract(STYLE_COLOR,  0, 8)
		const src_g = bit32.extract(STYLE_COLOR,  8, 8)
		const src_b = bit32.extract(STYLE_COLOR, 16, 8)
		const advance = CHAR_WIDTH + CHAR_PADDING


		local cx, cy = px, py
		local this_offset, this_code = iterate_codes(text, 0)

		while this_code do
			if this_code == 10 then -- '\n'
				cx = px
				cy += CHAR_HEIGHT
			elseif this_code ~= 13 then -- skip '\r'
				local glyph = GLYPH_CACHE[this_code]
				if not glyph then
					glyph = rasterize_glyph(this_code)
					GLYPH_CACHE[this_code] = glyph
				end

				-- Fast path: whole glyph lies inside the current clip rect.
				if
					cx >= CLIP_X_MIN and cy >= CLIP_Y_MIN
					and cx + CHAR_WIDTH - 1 <= CLIP_X_MAX
					and cy + CHAR_HEIGHT - 1 <= CLIP_Y_MAX
				then
					local init_offset = cy * ROW_STRIDE + cx * 4
					local idx = 0

					for _ = 1, CHAR_HEIGHT do
						local offset = init_offset
						for _ = 1, CHAR_WIDTH do
							const ga = buffer.readu8(glyph, idx)
							if ga ~= 0 then
								const sa = (src_a * ga + 127) // 255
								-- Fully opaque: skip the read-modify-write.
								if sa == 255 then
									buffer.writeu32(IMAGE, offset, STYLE_COLOR)
								elseif sa ~= 0 then
									const dst = buffer.readu32(IMAGE, offset)
									const da  = bit32.extract(dst, 24, 8)
									const inv = 255 - sa

									-- Per-channel source-over in 8-bit.
									const oa = sa + (da * inv + 127) // 255
									const or_ = (src_r * sa + bit32.extract(dst,  0, 8) * inv + 127) // 255
									const og  = (src_g * sa + bit32.extract(dst,  8, 8) * inv + 127) // 255
									const ob  = (src_b * sa + bit32.extract(dst, 16, 8) * inv + 127) // 255

									buffer.writeu32(
										IMAGE, offset,
										bit32.bor(
											bit32.lshift(oa,  24),
											bit32.lshift(or_,  0),
											bit32.lshift(og,   8),
											bit32.lshift(ob,  16)
										)
									)
								end
								buffer.writeu32(W, offset, F32_INF)
							end
							offset += 4
							idx += 1
						end
						init_offset += ROW_STRIDE
					end
				else
					-- Slow path: per-pixel scissor test.
					for y = 0, CHAR_HEIGHT - 1 do
						const wy = cy + y

						if wy >= CLIP_Y_MIN and wy <= CLIP_Y_MAX then
							const init_offset = wy * ROW_STRIDE
							local idx = y * CHAR_WIDTH

							for wx = cx, cx + CHAR_WIDTH - 1 do
								if wx >= CLIP_X_MIN and wx <= CLIP_X_MAX then
									const ga = buffer.readu8(glyph, idx)
									if ga ~= 0 then
										const offset = init_offset + wx * 4
										const sa = (src_a * ga + 127) // 255
										-- Fully opaque: skip the read-modify-write.
										if sa == 255 then
											buffer.writeu32(IMAGE, offset, STYLE_COLOR)
										elseif sa ~= 0 then
											const dst = buffer.readu32(IMAGE, offset)
											const da  = bit32.extract(dst, 24, 8)
											const inv = 255 - sa

											const oa = sa + (da * inv + 127) // 255
											const or_ = (src_r * sa + bit32.extract(dst,  0, 8) * inv + 127) // 255
											const og  = (src_g * sa + bit32.extract(dst,  8, 8) * inv + 127) // 255
											const ob  = (src_b * sa + bit32.extract(dst, 16, 8) * inv + 127) // 255

											buffer.writeu32(
												IMAGE, offset,
												bit32.bor(
													bit32.lshift(oa,  24),
													bit32.lshift(or_,  0),
													bit32.lshift(og,   8),
													bit32.lshift(ob,  16)
												)
											)
										end
										buffer.writeu32(W, offset, F32_INF)
									end
								end
								idx += 1
							end
						end
					end
				end

				cx += advance
			end

			this_offset, this_code = iterate_codes(text, this_offset)
		end
	end

	return {
		getTextBounds = GET_TEXT_BOUNDS;

		setColor = SET_COLOR;
		setFont = SET_FONT;
		setTextSize = SET_TEXT_SIZE;
		setLineThickness = SET_LINE_THICKNESS;
		
		pushClip = PUSH_CLIP;
		popClip = POP_CLIP;
		getClipPosition = GET_CLIP_POSITION;
		getClipBounds = GET_CLIP_BOUNDS;

		line = LINE;
		rectangle = RECTANGLE;
		text = TEXT;

		getRenderResolution = GET_RENDER_RESOLUTION;
		setRenderResolution = SET_RENDER_RESOLUTION;
	}
end