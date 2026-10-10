
-- A simple text buffer for debugger text.
-- MIT Licensed | @AnotherSubatomo (GitHub)

--!strict
--!optimize 2
--!native

type valid = string | number | boolean | Vector3
type value = valid | {[string]: value}

const NEW_LINE = '\n'
const FIELD_SEPARATOR = ': '
const TAB_CHAR = 9

const MARK_BEGIN = '' --'<mark color="#000000">'
const MARK_END = '' --'</mark>'
const MARK_BEGIN_SIZE = #MARK_BEGIN
const MARK_END_SIZE = #MARK_END

const BUFFER_LIMIT = 2^11 + MARK_BEGIN_SIZE
local BUFFER_OFFSET = MARK_BEGIN_SIZE
const BUFFER = buffer.create(BUFFER_LIMIT + MARK_END_SIZE)

buffer.writestring(BUFFER, 0, MARK_BEGIN)

const function write_string(str: string): ()
	local bytes = #str
	const old_offset = BUFFER_OFFSET
	BUFFER_OFFSET += bytes

	if BUFFER_OFFSET > BUFFER_LIMIT then
		BUFFER_OFFSET = BUFFER_LIMIT
		bytes = BUFFER_OFFSET - old_offset
	end

	buffer.writestring(BUFFER, old_offset, str, bytes)
end

const function write_tabs(n: number): ()
	if n == 0 then return end
	const old_offset = BUFFER_OFFSET
	BUFFER_OFFSET += n

	if BUFFER_OFFSET > BUFFER_LIMIT then
		BUFFER_OFFSET = BUFFER_LIMIT
		n = BUFFER_OFFSET - old_offset
	end

	buffer.fill(BUFFER, old_offset, TAB_CHAR, n)
end

const function write_field(name: string, value: value, level: number): ()
	if typeof(value) == "table" then
		write_string(NEW_LINE)
		write_tabs(level)
		write_string(name)
		write_string(FIELD_SEPARATOR)

		for metaname: string, metavalue: value in value do
			if BUFFER_OFFSET == BUFFER_LIMIT then return end
			write_field(metaname, metavalue, level + 1)
		end
	else
		write_string(NEW_LINE)
		write_tabs(level)
		write_string(name)
		write_string(FIELD_SEPARATOR)
		write_string(tostring(value))
	end
end

const function WRITE(name: string, value: value): ()
	if BUFFER_OFFSET == BUFFER_LIMIT then return end
	write_field(name, value, 0)
end

const function FLUSH(): (string)
	buffer.writestring(BUFFER, BUFFER_OFFSET, MARK_END)
	const render = buffer.readstring(BUFFER, 0, BUFFER_OFFSET + MARK_END_SIZE)

	buffer.fill(BUFFER, MARK_BEGIN_SIZE, BUFFER_LIMIT)
	BUFFER_OFFSET = MARK_BEGIN_SIZE
	return render
end

return {
	write = WRITE,
	flush = FLUSH,
}