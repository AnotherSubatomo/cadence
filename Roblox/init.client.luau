
-- Roblox runtime for AnotherSubatomo/cadence.

--!strict
--!optimize 2
--!native

_G.ROBLOX = true
const New = Instance.new

const DebugBuffer = require("@self/DebugBuffer")

const program = require("@self/src")
const max_resolution = program.max_resolution
const frame = program.frame
const set_input = program.set_input
const set_view_resolution = program.set_view_resolution
const get_debug_info = program.get_debug_info

const THEME_COLOR = Color3.fromHex 'c86809'
const THEME_PADDING = UDim.new(0, 4)
const THEME_PADDING_HALF = UDim.new(0, THEME_PADDING.Offset / 2)

const EMPTY_STRING = ''

const function get_mouse_states(mouse_buttons: {InputObject}): (vector)
	local left, middle, right = 0, 0, 0
	for _, button in mouse_buttons do
		const type = button.UserInputType
		if type == Enum.UserInputType.MouseButton1 then left = 1
		elseif type == Enum.UserInputType.MouseButton2 then right = 1
		elseif type == Enum.UserInputType.MouseButton3 then middle = 1
		end
	end
	return vector.create(left, middle, right)
end

const function get_move_direction(intrinsic_move_vector: Vector3, keys: {InputObject}): (vector)
	local up_move = 0

	for _, key in keys do
		const code = key.KeyCode.Value

		if code == 101 then up_move += 1
		elseif code == 113 then up_move -= 1
		end
	end

	return vector.create(-intrinsic_move_vector.X, up_move, -intrinsic_move_vector.Z)
end

const function ListFrame(direction: Enum.FillDirection): (Frame)
	const frame = New 'Frame'
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromScale(0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0

	const layout = New 'UIListLayout'
	layout.FillDirection = direction
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = THEME_PADDING
	layout.Parent = frame

	return frame
end

const function Snap(ui: GuiObject, corner: Vector2, padding: number): ()
	const x, y = corner.X, corner.Y
	ui.AnchorPoint = corner
	ui.Position = UDim2.new(x, (x > 0 and -1 or 1) * padding, y, (y > 0 and -1 or 1) * padding)
end

const function ThemeBorder(ui: GuiObject): ()
	const padder = New 'UIPadding'
	padder.PaddingLeft = THEME_PADDING
	padder.PaddingRight = THEME_PADDING
	padder.PaddingTop = THEME_PADDING_HALF
	padder.PaddingBottom = THEME_PADDING_HALF

	const border = New 'UIStroke'
	border.Color = THEME_COLOR
	border.Thickness = 0.75
	border.LineJoinMode = Enum.LineJoinMode.Round
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

	const corner = New 'UICorner'
	corner.CornerRadius = THEME_PADDING

	padder.Parent = ui
	border.Parent = ui
	corner.Parent = ui
end

const function ThemeText<T>(text_ui: (TextLabel | TextBox | TextButton) & T): (T)
	text_ui.AutomaticSize = Enum.AutomaticSize.XY
	text_ui.Size = UDim2.fromScale(0, 0)
	text_ui.BackgroundTransparency = 1
	text_ui.BorderSizePixel = 0
	text_ui.ZIndex = 1
	text_ui.FontFace = Font.fromName 'RobotoMono'
	text_ui.TextColor3 = THEME_COLOR
	text_ui.TextSize = 12
	return text_ui
end

const function Form(callback: (...string) -> (), submit_text: string, ...: string): (Frame)
	const inputs_n = select('#', ...)
	const inputs = table.create(inputs_n) :: {TextBox}
	const input_values = table.create(inputs_n, EMPTY_STRING)
	const container = ListFrame(Enum.FillDirection.Horizontal)

	for order, placeholder in {...} do
		const input = ThemeText(New 'TextBox')
		input.PlaceholderText = placeholder
		input.LayoutOrder = order
		input.Text = EMPTY_STRING
		input.Parent = container
		inputs[order] = input
		ThemeBorder(input)
	end

	const submit = ThemeText(New 'TextButton')
	submit.Text = submit_text
	submit.LayoutOrder = inputs_n + 1
	submit.Parent = container
	ThemeBorder(submit)

	const function submit_handler(): ()
		for order, input in inputs do
			input_values[order] = input.Text
		end
		callback(unpack(input_values))
	end

	submit.Activated:Connect(submit_handler)
	return container
end

const function main()
	const Players = game:GetService 'Players'
	const Asset = game:GetService 'AssetService'
	const Run = game:GetService 'RunService'
	const UserInput = game:GetService 'UserInputService'

	const Client = Players.LocalPlayer

	const ClientCore = require(Client.PlayerScripts:WaitForChild 'PlayerModule') :: any
	const ClientControls = ClientCore:GetControls()

	const UI = New 'ScreenGui'
	UI.ResetOnSpawn = false
	UI.IgnoreGuiInset = true
	UI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	UI.DisplayOrder = -1

	const Backdrop = New 'Frame'
	Backdrop.Size = UDim2.fromScale(1, 1)
	Backdrop.BackgroundColor3 = Color3.fromHex '000000'
	Backdrop.ZIndex = -1

	const Viewport = New 'ImageLabel'
	Viewport.Size = UDim2.fromScale(1, 1)
	Viewport.Position = UDim2.fromScale(0.5, 0.5)
	Viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	Viewport.BackgroundTransparency = 1
	Viewport.ResampleMode = Enum.ResamplerMode.Pixelated

	const AspectRatio = New 'UIAspectRatioConstraint'
	AspectRatio.Parent = Viewport

	local view_size = Vector2.new(max_resolution.x, max_resolution.y)
	local write_buffer_size = view_size.X * view_size.Y * 4
	local write_buffer = buffer.create(write_buffer_size)
	AspectRatio.AspectRatio = view_size.X / view_size.Y
	Viewport.ImageRectSize = view_size

	const function resize_handler(width_str: string, height_str: string): ()
		Run.PreSimulation:Wait()
		const width = tonumber(width_str)
		const height = tonumber(height_str)
		if not width or not height then return end

		set_view_resolution(vector.create(width, height))

		view_size = Vector2.new(width, height)
		write_buffer_size = view_size.X * view_size.Y * 4
		write_buffer = buffer.create(write_buffer_size)
		AspectRatio.AspectRatio = view_size.X / view_size.Y
		Viewport.ImageRectSize = view_size
	end

	const function get_canvas_mouse_position(position: Vector2): (vector)
		-- Get client mouse position
		const client_x = position.X
		const client_y = position.Y - 58

		-- Get local coordinates within the viewport
		const rect_position = Viewport.AbsolutePosition
		const local_x = client_x - rect_position.X
		const local_y = client_y - rect_position.Y

		-- Normalize coordinates relative to the viewport size
		const rect_size = Viewport.AbsoluteSize
		const relative_x = local_x / rect_size.X
		const relative_y = local_y / rect_size.Y

		-- Map to internal canvas resolution pixels (0 to canvas.width/height)
		const x = relative_x * view_size.X
		const y = relative_y * view_size.Y
		return vector.create(x, y)
	end

	const DebugMenu = ThemeText(New 'TextLabel')
	Snap(DebugMenu, Vector2.new(0, 1), 20)
	DebugMenu.TextXAlignment = Enum.TextXAlignment.Right
	DebugMenu.RichText = true

	const ConfigMenu = ListFrame(Enum.FillDirection.Vertical)
	Snap(ConfigMenu, Vector2.new(1, 0), 20)

	const Resizer = Form(resize_handler, 'Resize', 'Width', 'Height')
	Resizer.Parent = ConfigMenu

	const Image = Asset:CreateEditableImage { Size = view_size }
	const ImageContent = Content.fromObject(Image)

	const function render(delta: number): ()
		const mouse_location = UserInput:GetMouseLocation()
		const mouse_delta = (UserInput:GetMouseDelta() :: any) :: vector

		const mouse_buttons_pressed = UserInput:GetMouseButtonsPressed()
		const client_move_vector = ClientControls:GetMoveVector()
		const keys_pressed = UserInput:GetKeysPressed()

		const mouse_position = get_canvas_mouse_position(mouse_location)
		const mouse_states = get_mouse_states(mouse_buttons_pressed)
		const move_direction = get_move_direction(client_move_vector, keys_pressed)

		set_input(mouse_position, mouse_delta, mouse_states, move_direction)

		const ImageBuffer = frame(delta)
		buffer.copy(write_buffer, 0, ImageBuffer, 0, write_buffer_size)
		Image:WritePixelsBuffer(Vector2.zero, view_size, write_buffer)

		const debug_info = get_debug_info()
		const budget = debug_info.budget_consumed_percent * 1000 // 1 / 1000

		DebugBuffer.write('Frame budget consumed (%)',' <b>' .. budget .. '</b>')
		DebugMenu.Text = DebugBuffer.flush()
	end

	Run.PreRender:Connect(render)

	Viewport.ImageContent = ImageContent
	Viewport.Parent = UI
	Backdrop.Parent = UI
	DebugMenu.Parent = UI
	ConfigMenu.Parent = UI
	UI.Parent = Client.PlayerGui

	repeat task.wait() until Client.Character
	const Character = Client.Character :: Model
	const Humanoid = Character:WaitForChild "Humanoid" :: Humanoid

	Humanoid.WalkSpeed = 0
end

main()