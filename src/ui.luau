
--[=[
	ui - minimal immediate mode UI library in pure Luau.
	Author: @AnotherSubatomo (GitHub)
	SPDX-License-Identifier: MIT
]=]

--!strict
--!optimize 2
--!native

-- # Type definitions

type function nullable(t: type): (type)
	for key in t:properties() do
		const property = t:readproperty(key) :: type
		t:setproperty(key, types.optional(property))
	end
	return t
end

-- Visual appearance of every widget.
export type Style = {
	font_size: number,
	padding_x: number,
	padding_y: number,
	spacing: number,
	widget_height: number,
	color_widget: number,
	color_widget_hot: number,
	color_widget_active: number,
	color_border: number,
	color_text: number,
}

-- Drawing interface the IMGUI library depends on.
export type Renderer = {
	getTextSize: (text: string) -> (number, number),
	setColor: (color: number) -> (),
	setTextSize: (size: number) -> (),
	line: (...vector) -> (),
	rectangle: (vector, vector) -> (),
	text: (vector, string) -> (),
}

-- Layout state saved while inside a group.
export type GroupState = {
	origin_x: number,
	origin_y: number,
	cursor_x: number,
	cursor_y: number,
	line_height: number,
	first_in_line: boolean,
}

-- # Module constants

-- Default look and feel of every widget.
const DEFAULT_STYLE: Style = {
	font_size = 7,
	padding_x = 3,
	padding_y = 3,
	spacing = 3,
	widget_height = 12,
	color_widget = 0xFF3C3C3C,
	color_widget_hot = 0xFF4E4E4E,
	color_widget_active = 0xFF5F5F5F,
	color_border = 0xFF808080,
	color_text = 0xFFFFFFFF,
}

const DEBUG_INFO_LINE = 'l'
const FNV_OFFSET = 2166136261
const FNV_PRIME = 16777619

-- # Module helpers

-- Hashes a string to a 32-bit unsigned integer.
const function hash_string(text: string): (number)
	local hash = 0
	for index = 1, #text do
		hash = bit32.band(hash * 31 + string.byte(text, index), 0xFFFFFFFF)
	end
	return hash
end

-- Returns true when the point lies inside the axis-aligned rectangle.
const function point_in_rect(px: number, py: number, x: number, y: number, w: number, h: number): (boolean)
	return px >= x and px < x + w and py >= y and py < y + h
end

-- # Factory

-- Builds a new IMGUI instance bound to the given renderer.
return function(draw: Renderer)
	-- Editable copy of the default style.
	const style: Style = table.clone(DEFAULT_STYLE)

	-- Per-frame input snapshot.
	local mouse_x = 0
	local mouse_y = 0
	local mouse_down = false
	local mouse_pressed = false
	local mouse_released = false
	local prev_mouse_down = false

	-- Cross-frame interaction state.
	local hot_id = 0
	local active_id = 0

	-- Layout cursor.
	local origin_x = 0
	local origin_y = 0
	local cursor_x = 0
	local cursor_y = 0
	local line_height = 0
	local same_line_next = false
	local first_in_line = true

	-- Identifier scope stack.
	const id_stack: {number} = { FNV_OFFSET }
	local id_stack_n = 1

	-- Saved layout snapshots for groups.
	const group_stack: {GroupState} = {}

	-- # Identifier helpers

	-- Returns the identifier of the innermost scope.
	const function current_id(): (number)
		return id_stack[id_stack_n]
	end

	-- Derives a stable numeric identifier from a label.
	const function make_id(): (number)
		const prev_id = current_id()
		const line_number = debug.info(2, DEBUG_INFO_LINE) :: number
		-- ^^^ logically, this should start at 3; but since it gets inlined, we subtract 1 from the stack
		return bit32.band((bit32.bxor(prev_id, line_number) * FNV_PRIME), 0xFFFFFFFF)
	end

	-- Pushes a scoping identifier derived from the given label.
	const function PUSH_ID(value: string | number | {any} | (any) -> (any)): ()
		const prev_id = current_id()
		const this_id =
			if type(value) == "number"
			then bit32.band((bit32.bxor(prev_id, value) * FNV_PRIME), 0xFFFFFFFF)
			else hash_string(tostring(value))

		id_stack_n += 1
		id_stack[id_stack_n] = this_id
	end

	-- Pops the innermost identifier.
	const function POP_ID(): ()
		id_stack[id_stack_n] = nil
		id_stack_n -= 1
	end

	-- # Drawing helpers

	-- Measures the given text at the current font size.
	const function measure(text: string): (number, number)
		draw.setTextSize(style.font_size)
		return draw.getTextSize(text)
	end

	-- Draws text using the current text color and font size.
	const function draw_text(text: string, x: number, y: number): ()
		draw.setColor(style.color_text)
		draw.setTextSize(style.font_size)
		draw.text(vector.create(x, y), text)
	end

	-- Draws a one pixel outline around the given rectangle.
	const function outline(x: number, y: number, width: number, height: number): ()
		draw.setColor(style.color_border)
		draw.line(
			vector.create(x, y),
			vector.create(x + width - 1, y),
			vector.create(x + width - 1, y + height - 1),
			vector.create(x, y + height - 1),
			vector.create(x, y)
		)
	end

	-- Advances the layout cursor and returns the reserved top-left corner.
	const function reserve_space(width: number, height: number): (number, number)
		const w = width // 1
		const h = height // 1

		if first_in_line then
			first_in_line = false
			line_height = h
		elseif same_line_next then
			line_height = math.max(line_height, h)
		else
			cursor_y += line_height + style.spacing
			cursor_x = origin_x
			line_height = h
		end

		same_line_next = false

		const x = cursor_x // 1
		const y = cursor_y // 1
		cursor_x += w + style.spacing
		return x, y
	end

	-- # Frame lifecycle

	-- Starts a new frame and records the input snapshot.
	const function BEGIN(mx: number, my: number, mdown: boolean, ox: number?, oy: number?): ()
		mouse_x = mx
		mouse_y = my
		mouse_pressed = mdown and not prev_mouse_down
		mouse_released = (not mdown) and prev_mouse_down
		prev_mouse_down = mdown
		mouse_down = mdown

		hot_id = 0
		origin_x = ox or style.padding_x
		origin_y = oy or style.padding_y
		cursor_x = origin_x
		cursor_y = origin_y
		line_height = 0
		same_line_next = false
		first_in_line = true

		table.clear(id_stack)
		id_stack[1] = 0
		table.clear(group_stack)
	end

	-- Ends the current frame.
	const function FINISH(): ()
		if not mouse_down then
			active_id = 0
		end
	end

	-- Applies partial style overrides.
	const function SET_STYLE(overrides: nullable<Style>): ()
		for key, value in overrides :: {any} do
			(style :: {any})[key] = value
		end
	end

	-- # Layout controls

	-- Returns the current cursor position.
	const function GET_CURSOR(): (number, number)
		return cursor_x, cursor_y
	end

	-- Sets both the layout origin and the cursor.
	const function SET_CURSOR(x: number, y: number): ()
		origin_x = x
		origin_y = y
		cursor_x = x
		cursor_y = y
		line_height = 0
		first_in_line = true
		same_line_next = false
	end

	-- Makes the next widget share the current line.
	const function SAME_LINE(): ()
		same_line_next = true
	end

	-- Advances the cursor by a blank line (or by the given amount).
	const function SPACING(amount: number?): ()
		const gap = amount or style.spacing
		cursor_y += (if first_in_line then 0 else line_height) + gap
		cursor_x = origin_x
		line_height = 0
		first_in_line = true
		same_line_next = false
	end

	-- Starts a nested layout region anchored at the given position.
	const function BEGIN_GROUP(x: number, y: number): ()
		group_stack[#group_stack + 1] = {
			origin_x = origin_x,
			origin_y = origin_y,
			cursor_x = cursor_x,
			cursor_y = cursor_y,
			line_height = line_height,
			first_in_line = first_in_line,
		}
		origin_x = x
		origin_y = y
		cursor_x = x
		cursor_y = y
		line_height = 0
		first_in_line = true
		same_line_next = false
	end

	-- Ends the most recent group and restores the outer layout.
	const function END_GROUP(): ()
		const saved = table.remove(group_stack)
		if not saved then
			return
		end
		origin_x = saved.origin_x
		origin_y = saved.origin_y
		cursor_x = saved.cursor_x
		cursor_y = saved.cursor_y
		line_height = saved.line_height
		first_in_line = saved.first_in_line
	end

	-- # Widgets

	-- Draws a plain text label.
	const function LABEL(text: string): ()
		const text_width, text_height = measure(text)
		const x, y = reserve_space(text_width, text_height)
		draw_text(text, x, y)
	end

	-- Draws a horizontal separator line.
	const function SEPARATOR(width: number?): ()
		const w = width or 160
		const x, y = reserve_space(w, 1)
		draw.setColor(style.color_border)
		draw.line(
			vector.create(x, y),
			vector.create(x + w, y)
		)
	end

	-- Draws a button; returns true when it was clicked this frame.
	const function BUTTON(text: string, width: number?, height: number?): (boolean)
		const text_width, text_height = measure(text)
		const w = (width or (text_width + style.padding_x * 2)) // 1
		const h = (height or style.widget_height) // 1
		const x, y = reserve_space(w, h)

		const id = make_id()
		const over = point_in_rect(mouse_x, mouse_y, x, y, w, h)
		if over then
			hot_id = id
		end

		local clicked = false
		if active_id == id then
			if mouse_released then
				if over then
					clicked = true
				end
				active_id = 0
			end
		elseif over and mouse_pressed then
			active_id = id
		end

		local fill = style.color_widget
		if active_id == id then
			fill = style.color_widget_active
		elseif hot_id == id then
			fill = style.color_widget_hot
		end

		draw.setColor(fill)
		draw.rectangle(vector.create(x, y), vector.create(w, h))
		outline(x, y, w, h)
		draw_text(text, x + (w - text_width) // 2, y + (h - text_height) // 2)
		return clicked
	end

	-- Draws a checkbox; returns the new value and whether it changed.
	const function CHECKBOX(text: string, value: boolean): (boolean, boolean)
		const box = (style.widget_height - 4) // 1
		const text_width, text_height = measure(text)
		const w = box + style.spacing + text_width
		const h = style.widget_height
		const x, y = reserve_space(w, h)

		const id = make_id()
		const over = point_in_rect(mouse_x, mouse_y, x, y, w, h)
		if over then
			hot_id = id
		end

		local new_value = value
		local changed = false
		if active_id == id then
			if mouse_released then
				if over then
					new_value = not value
					changed = true
				end
				active_id = 0
			end
		elseif over and mouse_pressed then
			active_id = id
		end

		const box_y = y + (h - box) // 2
		local fill = style.color_widget
		if active_id == id then
			fill = style.color_widget_active
		elseif hot_id == id then
			fill = style.color_widget_hot
		end

		draw.setColor(fill)
		draw.rectangle(vector.create(x, box_y), vector.create(box, box))
		outline(x, box_y, box, box)

		if new_value then
			draw.setColor(style.color_text)
			draw.line(
				vector.create(x + 2, box_y + box // 2),
				vector.create(x + box // 2, box_y + box - 3),
				vector.create(x + box - 2, box_y + 2)
			)
		end

		draw_text(text, x + box + style.spacing, y + (h - text_height) // 2)
		return new_value, changed
	end

	-- Draws a horizontal slider; returns the new value and whether it changed.
	const function SLIDER(text: string, value: number, min: number, max: number, width: number?): (number, boolean)
		const w = (width or 160) // 1
		const h = style.widget_height
		const x, y = reserve_space(w, h)

		const id = make_id()
		const over = point_in_rect(mouse_x, mouse_y, x, y, w, h)
		if over then
			hot_id = id
		end

		local new_value = value
		local changed = false
		if active_id == id then
			if mouse_down then
				const t = math.clamp((mouse_x - x) / (w - 1), 0, 1)
				const v = min + (max - min) * t
				if v ~= value then
					new_value = v
					changed = true
				end
			else
				active_id = 0
			end
		elseif over and mouse_pressed then
			active_id = id
		end

		draw.setColor(style.color_widget)
		draw.rectangle(vector.create(x, y), vector.create(w, h))

		const t = math.clamp((new_value - min) / (max - min), 0, 1)
		const filled_w = math.max(1, (t * w) // 1)
		draw.setColor(style.color_widget_active)
		draw.rectangle(vector.create(x, y), vector.create(filled_w, h))
		outline(x, y, w, h)

		const label_text = string.format("%s: %.2f", text, new_value)
		const text_width, text_height = measure(label_text)
		draw_text(label_text, x + (w - text_width) // 2, y + (h - text_height) // 2)
		return new_value, changed
	end

	-- Draws a progress bar reflecting the given value.
	const function PROGRESS_BAR(value: number, min: number, max: number, width: number?): ()
		const w = (width or 160) // 1
		const h = style.widget_height
		const x, y = reserve_space(w, h)

		draw.setColor(style.color_widget)
		draw.rectangle(vector.create(x, y), vector.create(w, h))

		const t = math.clamp((value - min) / (max - min), 0, 1)
		const filled_w = math.max(1, (t * w) // 1)
		draw.setColor(style.color_widget_active)
		draw.rectangle(vector.create(x, y), vector.create(filled_w, h))
		outline(x, y, w, h)

		const label_text = string.format("%d%%", math.floor(t * 100 + 0.5))
		const text_width, text_height = measure(label_text)
		draw_text(label_text, x + (w - text_width) // 2, y + (h - text_height) // 2)
	end

	-- Draws a filled panel with an outline.
	const function PANEL(x: number, y: number, width: number, height: number): ()
		draw.setColor(style.color_widget)
		draw.rectangle(vector.create(x, y), vector.create(width, height))
		outline(x, y, width, height)
	end

	return {
		pushId = PUSH_ID,
		popId = POP_ID,

		setStyle = SET_STYLE,
		getCursor = GET_CURSOR,
		setCursor = SET_CURSOR,

		begin = BEGIN,
		finish = FINISH,
		sameLine = SAME_LINE,
		spacing = SPACING,
		beginGroup = BEGIN_GROUP,
		endGroup = END_GROUP,
		label = LABEL,
		separator = SEPARATOR,
		button = BUTTON,
		checkbox = CHECKBOX,
		slider = SLIDER,
		progressBar = PROGRESS_BAR,
		panel = PANEL,
	}
end