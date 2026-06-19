extends Control

var _font : Font

func _ready() -> void:
	_font = load("res://assets/Poppins-Medium.ttf") as Font

	# ── Dark background ──────────────────────────────────────────────────────
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.12, 1.0)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)

	# ── Centre container ─────────────────────────────────────────────────────
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	add_child(vbox)

	# ── Title ────────────────────────────────────────────────────────────────
	var title := _label("MATCH SETTINGS", 52, Color(1.0, 0.92, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 4)
	vbox.add_child(title)

	var spacer0 := Control.new()
	spacer0.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer0)

	# ── Settings rows (centered with fixed width) ────────────────────────────
	var center_box := CenterContainer.new()
	vbox.add_child(center_box)

	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 16)
	grid.custom_minimum_size = Vector2(520, 0)
	center_box.add_child(grid)

	# Round time
	_add_setting_row(grid, "Round Time", _create_time_selector())

	# Engine power
	_add_setting_row(grid, "Engine Power", _create_slider(500, 3000, GameSettings.engine_power, func(v: float) -> void: GameSettings.engine_power = v))

	# Braking power
	_add_setting_row(grid, "Braking", _create_slider(500, 3000, GameSettings.braking_power, func(v: float) -> void: GameSettings.braking_power = v))

	# Steering angle
	_add_setting_row(grid, "Steering", _create_slider(10, 90, GameSettings.steering_angle, func(v: float) -> void: GameSettings.steering_angle = v))

	# ── Spacer ───────────────────────────────────────────────────────────────
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(spacer)

	# ── Buttons ──────────────────────────────────────────────────────────────
	var btn_start := _make_button("START GAME")
	btn_start.pressed.connect(_on_start)
	vbox.add_child(btn_start)

	var btn_back := _make_button("BACK")
	btn_back.pressed.connect(_on_back)
	vbox.add_child(btn_back)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _add_setting_row(parent: Control, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := _label(label_text, 24, Color(0.8, 0.8, 0.9))
	lbl.custom_minimum_size = Vector2(180, 0)
	row.add_child(lbl)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)


func _create_time_selector() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var options := [300, 600, 900, 1200, 1800]
	var labels  := ["5:00", "10:00", "15:00", "20:00", "30:00"]

	for i in range(options.size()):
		var btn := Button.new()
		btn.text = labels[i]
		btn.custom_minimum_size = Vector2(60, 40)
		if _font != null:
			btn.add_theme_font_override("font", _font)
		btn.add_theme_font_size_override("font_size", 20)

		var time_val : float = float(options[i])
		btn.pressed.connect(_on_time_selected.bind(time_val, hbox))

		# Style
		var style := StyleBoxFlat.new()
		if absf(GameSettings.round_time - time_val) < 0.5:
			style.bg_color = Color(0.3, 0.35, 0.55, 1.0)
			style.border_color = Color(1.0, 0.92, 0.5, 0.9)
		else:
			style.bg_color = Color(0.15, 0.15, 0.22, 1.0)
			style.border_color = Color(0.4, 0.4, 0.55, 0.5)
		style.set_border_width_all(2)
		style.set_corner_radius_all(8)
		style.set_content_margin_all(8)
		btn.add_theme_stylebox_override("normal", style)
		btn.set_meta("time_val", time_val)
		hbox.add_child(btn)

	return hbox


func _on_time_selected(time_val: float, hbox: HBoxContainer) -> void:
	GameSettings.round_time = time_val
	# Update button visuals
	for child in hbox.get_children():
		if child is Button:
			var bv : float = child.get_meta("time_val")
			var style := StyleBoxFlat.new()
			if absf(bv - time_val) < 0.5:
				style.bg_color = Color(0.3, 0.35, 0.55, 1.0)
				style.border_color = Color(1.0, 0.92, 0.5, 0.9)
			else:
				style.bg_color = Color(0.15, 0.15, 0.22, 1.0)
				style.border_color = Color(0.4, 0.4, 0.55, 0.5)
			style.set_border_width_all(2)
			style.set_corner_radius_all(8)
			style.set_content_margin_all(8)
			child.add_theme_stylebox_override("normal", style)


func _create_slider(min_val: float, max_val: float, current: float, on_change: Callable) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = current
	slider.step = 10
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(slider)

	var val_label := _label(str(int(current)), 22, Color(1, 1, 1))
	val_label.custom_minimum_size = Vector2(50, 0)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(val_label)

	slider.value_changed.connect(func(v: float) -> void:
		val_label.text = str(int(v))
		on_change.call(v)
	)

	return hbox


func _make_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(420, 60)
	btn.add_theme_font_size_override("font_size", 32)
	btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 0.5))
	if _font != null:
		btn.add_theme_font_override("font", _font)

	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color = Color(0.15, 0.15, 0.22, 1.0)
	style_normal.border_color = Color(0.4, 0.4, 0.55, 0.6)
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(12)
	style_normal.set_content_margin_all(12)
	btn.add_theme_stylebox_override("normal", style_normal)

	var style_hover := StyleBoxFlat.new()
	style_hover.bg_color = Color(0.22, 0.22, 0.35, 1.0)
	style_hover.border_color = Color(1.0, 0.92, 0.5, 0.8)
	style_hover.set_border_width_all(2)
	style_hover.set_corner_radius_all(12)
	style_hover.set_content_margin_all(12)
	btn.add_theme_stylebox_override("hover", style_hover)

	return btn


func _on_start() -> void:
	get_tree().change_scene_to_file("res://main.tscn")


func _on_back() -> void:
	get_tree().change_scene_to_file("res://main_menu.tscn")
