extends Control

var _btn_local : Button
var _btn_exit  : Button


func _ready() -> void:
	# ── Dark background ──────────────────────────────────────────────────────
	var bg := ColorRect.new()
	bg.color = Color("#050505")
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)

	# ── Centre container ─────────────────────────────────────────────────────
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 24)
	add_child(vbox)

	var font = load("res://assets/Poppins-Medium.ttf") as Font

	# ── Title ────────────────────────────────────────────────────────────────
	var title := Label.new()
	title.text = "UNHINGED DELIVERY\nSIMULATOR"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 82)
	title.add_theme_color_override("font_color", Color("#fcee0a"))
	title.add_theme_color_override("font_outline_color", Color("#ff003c"))
	title.add_theme_constant_override("outline_size", 6)
	if font != null:
		title.add_theme_font_override("font", font)
	vbox.add_child(title)

	# ── Subtitle ─────────────────────────────────────────────────────────────
	var subtitle := Label.new()
	subtitle.text = "deliver packages. cause chaos."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 28)
	subtitle.add_theme_color_override("font_color", Color("#00f0ff"))
	if font != null:
		subtitle.add_theme_font_override("font", font)
	vbox.add_child(subtitle)

	# ── Spacer ───────────────────────────────────────────────────────────────
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 40)
	vbox.add_child(spacer)

	# ── Buttons ──────────────────────────────────────────────────────────────
	_btn_local = _make_button("LOCAL MULTIPLAYER", font)
	_btn_local.pressed.connect(_on_local_multiplayer)
	vbox.add_child(_btn_local)

	if not OS.has_feature("web"):
		var btn_host := _make_button("HOST ONLINE", font)
		btn_host.pressed.connect(_on_host_online)
		vbox.add_child(btn_host)

		var btn_join := _make_button("JOIN ONLINE", font)
		btn_join.pressed.connect(_on_join_online)
		vbox.add_child(btn_join)

		_btn_exit = _make_button("EXIT", font)
		_btn_exit.pressed.connect(_on_exit)
		vbox.add_child(_btn_exit)

	# ── Controls hint ────────────────────────────────────────────────────────
	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(spacer2)

	var hint := Label.new()
	hint.text = "Local: P1 WASD  •  P2 Arrow Keys\nOnline: WASD (both players)"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6, 0.6))
	if font != null:
		hint.add_theme_font_override("font", font)
	vbox.add_child(hint)


func _make_button(label: String, font: Font) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(280, 50)
	btn.add_theme_font_size_override("font_size", 24)
	btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_hover_color", Color("#ff003c"))

	# Style: normal (now uses hover colors always)
	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color = Color(1.0, 0.0, 0.24, 0.1) # tinted red
	style_normal.border_color = Color("#ff003c")
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(12)
	style_normal.set_content_margin_all(10)
	btn.add_theme_stylebox_override("normal", style_normal)

	# Style: hover (same as normal)
	var style_hover := StyleBoxFlat.new()
	style_hover.bg_color = Color(1.0, 0.0, 0.24, 0.1) # tinted red
	style_hover.border_color = Color("#ff003c")
	style_hover.set_border_width_all(2)
	style_hover.set_corner_radius_all(12)
	style_hover.set_content_margin_all(10)
	btn.add_theme_stylebox_override("hover", style_hover)

	# Style: pressed
	var style_pressed := StyleBoxFlat.new()
	style_pressed.bg_color = Color(1.0, 0.0, 0.24, 0.2)
	style_pressed.border_color = Color("#ff003c")
	style_pressed.set_border_width_all(3)
	style_pressed.set_corner_radius_all(12)
	style_pressed.set_content_margin_all(10)
	btn.add_theme_stylebox_override("pressed", style_pressed)

	btn.mouse_entered.connect(func():
		btn.pivot_offset = btn.size / 2.0
		var tween = btn.create_tween()
		tween.tween_property(btn, "scale", Vector2(1.05, 1.05), 0.1)
	)
	btn.mouse_exited.connect(func():
		var tween = btn.create_tween()
		tween.tween_property(btn, "scale", Vector2(1.0, 1.0), 0.1)
	)
	btn.button_down.connect(func():
		var tween = btn.create_tween()
		tween.tween_property(btn, "scale", Vector2(0.95, 0.95), 0.05)
	)
	btn.button_up.connect(func():
		var tween = btn.create_tween()
		tween.tween_property(btn, "scale", Vector2(1.05, 1.05), 0.1).set_trans(Tween.TRANS_BOUNCE)
	)

	if font != null:
		btn.add_theme_font_override("font", font)

	return btn


func _on_local_multiplayer() -> void:
	GameSettings.reset_network()
	get_tree().change_scene_to_file("res://scenes/settings_menu.tscn")


func _on_host_online() -> void:
	var lobby: Node = load("res://scenes/lobby_menu.tscn").instantiate()
	lobby.mode = "host"
	get_tree().root.add_child(lobby)
	queue_free()


func _on_join_online() -> void:
	var lobby: Node = load("res://scenes/lobby_menu.tscn").instantiate()
	lobby.mode = "join"
	get_tree().root.add_child(lobby)
	queue_free()


func _on_exit() -> void:
	get_tree().quit()
