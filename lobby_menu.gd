extends Control

## Lobby screen for online multiplayer.
## Supports two modes: "host" and "join", set via `mode` before _ready().

var mode : String = "host"   # "host" or "join"

var _font : Font
var _status_label : Label
var _btn_start : Button
var _btn_connect : Button
var _ip_edit : LineEdit
var _port_edit : LineEdit
var _peer_connected := false
var _vbox : VBoxContainer


func _ready() -> void:
	_font = load("res://assets/Poppins-Medium.ttf") as Font

	# ── Dark background ──────────────────────────────────────────────────────
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.12, 1.0)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)

	# ── Centre container ─────────────────────────────────────────────────────
	_vbox = VBoxContainer.new()
	_vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_theme_constant_override("separation", 18)
	add_child(_vbox)

	if mode == "host":
		_build_host_ui()
	else:
		_build_join_ui()


# ══════════════════════════════════════════════════════════════════════════════
#  HOST UI
# ══════════════════════════════════════════════════════════════════════════════

func _build_host_ui() -> void:
	# Title
	var title := _label("HOST GAME", 52, Color(1.0, 0.92, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 4)
	_vbox.add_child(title)

	# IP info
	var ip_lbl := _label("Your IP: Fetching...", 28, Color(0.6, 0.8, 1.0))
	ip_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(ip_lbl)
	
	var http_req = HTTPRequest.new()
	add_child(http_req)
	http_req.request_completed.connect(func(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var ip_str = body.get_string_from_utf8().strip_edges()
			ip_lbl.text = "Your IP: " + ip_str
		else:
			ip_lbl.text = "Your IP: " + _get_local_ip() + " (Local)"
		http_req.queue_free()
	)
	http_req.request("https://api.ipify.org")

	# Port row
	var port_row := HBoxContainer.new()
	port_row.alignment = BoxContainer.ALIGNMENT_CENTER
	port_row.add_theme_constant_override("separation", 12)
	_vbox.add_child(port_row)

	var port_lbl := _label("Port:", 24, Color(0.8, 0.8, 0.9))
	port_row.add_child(port_lbl)

	_port_edit = LineEdit.new()
	_port_edit.text = str(NetworkManager.DEFAULT_PORT)
	_port_edit.custom_minimum_size = Vector2(120, 40)
	_port_edit.add_theme_font_size_override("font_size", 22)
	if _font != null:
		_port_edit.add_theme_font_override("font", _font)
	port_row.add_child(_port_edit)

	_add_spacer(10)

	# ── Settings (same as settings_menu) ──────────────────────────────────────
	var settings_title := _label("MATCH SETTINGS", 32, Color(0.9, 0.85, 0.6))
	settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(settings_title)

	var center_box := CenterContainer.new()
	_vbox.add_child(center_box)

	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 14)
	grid.custom_minimum_size = Vector2(480, 0)
	center_box.add_child(grid)

	_add_setting_row(grid, "Round Time", _create_time_selector())
	_add_setting_row(grid, "Engine Power", _create_slider(500, 3000, GameSettings.engine_power,
		func(v: float) -> void: GameSettings.engine_power = v))
	_add_setting_row(grid, "Braking", _create_slider(500, 3000, GameSettings.braking_power,
		func(v: float) -> void: GameSettings.braking_power = v))
	_add_setting_row(grid, "Steering", _create_slider(10, 90, GameSettings.steering_angle,
		func(v: float) -> void: GameSettings.steering_angle = v))

	_add_spacer(10)

	# ── Status ────────────────────────────────────────────────────────────────
	_status_label = _label("Click START HOST to open lobby...", 24, Color(0.6, 0.6, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_status_label)

	# ── Buttons ───────────────────────────────────────────────────────────────
	_btn_start = _make_button("START HOST")
	_btn_start.pressed.connect(_on_host_pressed)
	_vbox.add_child(_btn_start)

	var btn_back := _make_button("BACK")
	btn_back.pressed.connect(_on_back)
	_vbox.add_child(btn_back)

	# Connect signals
	NetworkManager.player_connected.connect(_on_player_joined)
	NetworkManager.player_disconnected.connect(_on_player_left)


func _on_host_pressed() -> void:
	if not _peer_connected:
		# First click: start hosting
		var port := int(_port_edit.text) if _port_edit.text.is_valid_int() else NetworkManager.DEFAULT_PORT
		var err := NetworkManager.host_game(port)
		if err != OK:
			_status_label.text = "Failed to start server!"
			_status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
			return
		_status_label.text = "Waiting for player to join..."
		_status_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
		_btn_start.text = "WAITING..."
		_btn_start.disabled = true
		_port_edit.editable = false
	else:
		# Peer is connected, start the game
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var seed_val := rng.randi()
		NetworkManager.start_online_game(seed_val)


func _on_player_joined(_id: int) -> void:
	_peer_connected = true
	var count = NetworkManager.connected_peers.size() + 1
	_status_label.text = "Players connected: %d/4" % count
	_status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	_btn_start.text = "START GAME"
	_btn_start.disabled = false


func _on_player_left(_id: int) -> void:
	var count = NetworkManager.connected_peers.size() + 1
	if count <= 1:
		_peer_connected = false
		_status_label.text = "Player disconnected. Waiting..."
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
		_btn_start.text = "WAITING..."
		_btn_start.disabled = true
	else:
		_status_label.text = "Players connected: %d/4" % count


# ══════════════════════════════════════════════════════════════════════════════
#  JOIN UI
# ══════════════════════════════════════════════════════════════════════════════

func _build_join_ui() -> void:
	# Title
	var title := _label("JOIN GAME", 52, Color(1.0, 0.92, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 4)
	_vbox.add_child(title)

	_add_spacer(20)

	# IP row
	var ip_row := HBoxContainer.new()
	ip_row.alignment = BoxContainer.ALIGNMENT_CENTER
	ip_row.add_theme_constant_override("separation", 12)
	_vbox.add_child(ip_row)

	var ip_lbl := _label("Host IP:", 24, Color(0.8, 0.8, 0.9))
	ip_row.add_child(ip_lbl)

	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "e.g. 192.168.1.100"
	_ip_edit.custom_minimum_size = Vector2(300, 45)
	_ip_edit.add_theme_font_size_override("font_size", 24)
	if _font != null:
		_ip_edit.add_theme_font_override("font", _font)
	ip_row.add_child(_ip_edit)

	# Port row
	var port_row := HBoxContainer.new()
	port_row.alignment = BoxContainer.ALIGNMENT_CENTER
	port_row.add_theme_constant_override("separation", 12)
	_vbox.add_child(port_row)

	var port_lbl := _label("Port:", 24, Color(0.8, 0.8, 0.9))
	port_row.add_child(port_lbl)

	_port_edit = LineEdit.new()
	_port_edit.text = str(NetworkManager.DEFAULT_PORT)
	_port_edit.custom_minimum_size = Vector2(120, 40)
	_port_edit.add_theme_font_size_override("font_size", 22)
	if _font != null:
		_port_edit.add_theme_font_override("font", _font)
	port_row.add_child(_port_edit)

	_add_spacer(20)

	# Status
	_status_label = _label("Enter the host's IP address", 24, Color(0.6, 0.6, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_status_label)

	# Buttons
	_btn_connect = _make_button("CONNECT")
	_btn_connect.pressed.connect(_on_connect_pressed)
	_vbox.add_child(_btn_connect)

	var btn_back := _make_button("BACK")
	btn_back.pressed.connect(_on_back)
	_vbox.add_child(btn_back)

	# Connect signals
	NetworkManager.connection_succeeded.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connect_fail)
	NetworkManager.game_starting.connect(_on_game_starting)


func _on_connect_pressed() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip.is_empty():
		_status_label.text = "Please enter an IP address!"
		_status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		return

	var port := int(_port_edit.text) if _port_edit.text.is_valid_int() else NetworkManager.DEFAULT_PORT
	var err := NetworkManager.join_game(ip, port)
	if err != OK:
		_status_label.text = "Failed to connect!"
		_status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		return

	_status_label.text = "Connecting..."
	_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	_btn_connect.disabled = true
	_ip_edit.editable = false
	_port_edit.editable = false


func _on_connected() -> void:
	_status_label.text = "Connected! Waiting for host to start..."
	_status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))


func _on_connect_fail() -> void:
	_status_label.text = "Connection failed! Check IP and try again."
	_status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	_btn_connect.disabled = false
	_ip_edit.editable = true
	_port_edit.editable = true


func _on_game_starting(_settings: Dictionary) -> void:
	# Client received start signal — transition to game
	get_tree().change_scene_to_file("res://main.tscn")


# ══════════════════════════════════════════════════════════════════════════════
#  Shared UI helpers (matches settings_menu style)
# ══════════════════════════════════════════════════════════════════════════════

func _get_local_ip() -> String:
	var addrs := IP.get_local_addresses()
	for addr in addrs:
		# Prefer 192.168.x.x or 10.x.x.x addresses
		if addr.begins_with("192.168.") or addr.begins_with("10."):
			return addr
	for addr in addrs:
		if "." in addr and addr != "127.0.0.1":
			return addr
	return "127.0.0.1"


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _add_spacer(height: float) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, height)
	_vbox.add_child(s)


func _add_setting_row(parent: Control, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := _label(label_text, 22, Color(0.8, 0.8, 0.9))
	lbl.custom_minimum_size = Vector2(160, 0)
	row.add_child(lbl)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)


func _create_time_selector() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)

	var options := [300, 600, 900, 1200, 1800]
	var labels  := ["5:00", "10:00", "15:00", "20:00", "30:00"]

	for i in range(options.size()):
		var btn := Button.new()
		btn.text = labels[i]
		btn.custom_minimum_size = Vector2(55, 36)
		if _font != null:
			btn.add_theme_font_override("font", _font)
		btn.add_theme_font_size_override("font_size", 18)

		var time_val : float = float(options[i])
		btn.pressed.connect(_on_time_selected.bind(time_val, hbox))

		var style := StyleBoxFlat.new()
		if absf(GameSettings.round_time - time_val) < 0.5:
			style.bg_color = Color(0.3, 0.35, 0.55, 1.0)
			style.border_color = Color(1.0, 0.92, 0.5, 0.9)
		else:
			style.bg_color = Color(0.15, 0.15, 0.22, 1.0)
			style.border_color = Color(0.4, 0.4, 0.55, 0.5)
		style.set_border_width_all(2)
		style.set_corner_radius_all(8)
		style.set_content_margin_all(6)
		btn.add_theme_stylebox_override("normal", style)
		btn.set_meta("time_val", time_val)
		hbox.add_child(btn)

	return hbox


func _on_time_selected(time_val: float, hbox: HBoxContainer) -> void:
	GameSettings.round_time = time_val
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
			style.set_content_margin_all(6)
			child.add_theme_stylebox_override("normal", style)


func _create_slider(min_val: float, max_val: float, current: float, on_change: Callable) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = current
	slider.step = 10
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(180, 0)
	hbox.add_child(slider)

	var val_label := _label(str(int(current)), 20, Color(1, 1, 1))
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
	btn.custom_minimum_size = Vector2(380, 55)
	btn.add_theme_font_size_override("font_size", 28)
	btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 0.5))
	if _font != null:
		btn.add_theme_font_override("font", _font)

	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color = Color(0.15, 0.15, 0.22, 1.0)
	style_normal.border_color = Color(0.4, 0.4, 0.55, 0.6)
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(12)
	style_normal.set_content_margin_all(10)
	btn.add_theme_stylebox_override("normal", style_normal)

	var style_hover := StyleBoxFlat.new()
	style_hover.bg_color = Color(0.22, 0.22, 0.35, 1.0)
	style_hover.border_color = Color(1.0, 0.92, 0.5, 0.8)
	style_hover.set_border_width_all(2)
	style_hover.set_corner_radius_all(12)
	style_hover.set_content_margin_all(10)
	btn.add_theme_stylebox_override("hover", style_hover)

	return btn


func _on_back() -> void:
	NetworkManager.disconnect_game()
	GameSettings.reset_network()
	get_tree().change_scene_to_file("res://main_menu.tscn")


func _exit_tree() -> void:
	# Clean up signal connections
	if NetworkManager.player_connected.is_connected(_on_player_joined if mode == "host" else Callable()):
		pass  # signals auto-disconnect when node freed
