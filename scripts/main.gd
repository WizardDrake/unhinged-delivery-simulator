extends Node2D

const RoadPathGeneratorScript := preload("res://scripts/road_path_generator.gd")

# ── Scenes & textures ──────────────────────────────────────────────────────────
@export var straight_road_scene : PackedScene
@export var four_way_scene      : PackedScene  # all 4 roads meet
@export var three_way_scene     : PackedScene  # T-junction (base = missing north)
@export var l_corner_scene      : PackedScene  # 90° corner  (base = south + west)
@export var straight_inter_scene: PackedScene  # straight-through (base = north + south)
@export var car_scene           : PackedScene

const HOUSE_TEXTURE_PATH := "res://assets/house.svg"
const BOX_TEXTURE_PATH   := "res://assets/box.png"

# ── Grid config ────────────────────────────────────────────────────────────────
@export var grid_cols : int = 6
@export var grid_rows : int = 6

## Probability an interior road segment is placed (border is always 1.0).
@export_range(0.3, 1.0, 0.05) var road_density : float = 0.7

## Houses placed per curb side of each enclosed block.
@export var houses_per_side : int = 3

## Random seed (0 = randomise each run).
@export var map_seed : int = 0

# ── Geometry (measured from sprites at startup) ───────────────────────────────
const HOUSE_SCALE    := 1.125  # visual scale for house sprite
const CURB_OFFSET    := 500.0 # extra gap from road edge → house centre

# Filled in by _measure_scenes().
var _cell_size   : float = 5560.0
var _road_length : float = 4044.0
var _road_width  : float = 1516.0
var _inter_size  : float = 1516.0

# ── Internal state ─────────────────────────────────────────────────────────────
var _rng  := RandomNumberGenerator.new()

var _houses : Array[Sprite2D] = []
var _post_office : Sprite2D = null

# Per-player state
var _cars : Array[Node2D] = []
var _cameras : Array[Camera2D] = []
var _player_packages : Array[int] = []
var _player_scores   : Array[int] = []
var _player_targets  : Array = []  # Array of Array[Sprite2D]
var _ui_packages : Array[Label] = []
var _ui_scores   : Array[Label] = []

# Shop & Items state
var _player_has_item : Array[bool] = []
var _player_item_cooldown : Array[float] = []
var _ui_items : Array[Label] = []
var _ui_blind_screens : Array[ColorRect] = []
var _ui_item_menus : Array[PanelContainer] = []
var _ui_blind_particles : Array[CPUParticles2D] = []
var _blind_timers : Array[float] = []
var _player_selected_item : Array[int] = []
var _player_item_locked : Array[bool] = []
var ITEM_NAMES = ["Peanuts", "Oil (Slippery)", "Oil (Sticky)"]
var _oil_spills : Array[Dictionary] = []
var _boot_timers : Array[float] = []
var _cop_cooldown : Array[float] = []
var _camera_trauma : Array[float] = []
var _player_wanted : Array[bool] = []
var _cops : Array[Node2D] = []

# Legacy single-car reference for minimap compat
var _car : Node2D

# Thrown-box state
var _box_tex : Texture2D
var _thrown_boxes : Array = []  # Array of Dictionaries tracking each thrown box
const BOX_SCALE       := 6.0
const BOX_SPEED       := 3500.0
const BOX_HIT_DIST    := 300.0    # distance to house to count as collision
const BOX_BOUNCE_DIST := 220.0    # how far the box bounces back
const BOX_BOUNCE_TIME := 0.25     # seconds for the bounce animation
const BOX_LINGER_TIME := 0.5      # seconds box stays after bounce before vanishing

# h_segs[row][col] = true  →  horizontal road running right from node (col, row)
# v_segs[row][col] = true  →  vertical road running down from node (col, row)
var _h_segs : Array
var _v_segs : Array

var npc_car_scene = preload("res://scenes/npc_car.tscn")
var _npcs : Array[Node2D] = []
var _traffic_paths : Array = []

# ── Split-screen viewports ────────────────────────────────────────────────────
var _viewports : Array[SubViewport] = []
var _viewport_containers : Array[SubViewportContainer] = []

# ── Game Time & State ────────────────────────────────────────────────────────
var _game_state : String = "countdown" # "countdown", "playing", "finished"
var _countdown_timer : float = 3.0
var _round_timer : float = 0.0
var _ui_round_timers : Array[Label] = []
var _ui_center_labels : Array[Label] = []
var _ui_booted_labels : Array[Label] = []
var _global_results_screen : Control

# ── Per-player minimaps ───────────────────────────────────────────────────────
var _minimaps : Array[Control] = []  # one per player, inside their SubViewport

# Player colors for identification
const P1_COLOR := Color(0.3, 0.6, 1.0)   # blue
const P2_COLOR := Color(1.0, 0.35, 0.3)  # red
const P3_COLOR := Color(0.3, 0.9, 0.4)   # green
const P4_COLOR := Color(0.9, 0.8, 0.2)   # yellow
var _player_colors := [P1_COLOR, P2_COLOR, P3_COLOR, P4_COLOR]

# ── Online multiplayer state ──────────────────────────────────────────────────
var _local_player_idx  : int = 0   # host is 0, clients are assigned
var _last_tick : int = 0

func _ready() -> void:
	_last_tick = Time.get_ticks_msec()
	
	# Initialize player arrays
	for p in range(GameSettings.player_count):
		_player_packages.append(0)
		_player_scores.append(0)
		_player_targets.append([])
		_player_has_item.append(false)
		_player_item_cooldown.append(0.0)
		_blind_timers.append(0.0)
		_player_selected_item.append(0)
		_player_item_locked.append(false)
		_boot_timers.append(0.0)
		_cop_cooldown.append(0.0)
		_camera_trauma.append(0.0)
		_player_wanted.append(false)

	# ── Network mode setup ───────────────────────────────────────────────────
	if GameSettings.is_online:
		if GameSettings.is_host:
			_local_player_idx = 0
		else:
			_local_player_idx = GameSettings.peer_to_player_idx.get(multiplayer.get_unique_id(), 1)
		_rng.seed = GameSettings.network_seed
	elif map_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = map_seed

	_measure_scenes()
	_setup_split_screen()
	_spawn_grass_bg()       # must be first child so it draws behind everything
	_init_segment_arrays()
	_prune_dead_ends()
	_traffic_paths = RoadPathGeneratorScript.generate_paths(self, _rng, 14)
	_place_roads()
	_place_houses()
	_spawn_cars()
	_spawn_npcs()
	_build_minimap()
	
	for p in range(GameSettings.player_count):
		_update_ui(p)

	_box_tex = load(BOX_TEXTURE_PATH)

	_round_timer = GameSettings.round_time
	# Freeze cars during countdown
	for car in _cars:
		if car != null:
			car.frozen = true


# ── Split-screen setup ───────────────────────────────────────────────────────

func _setup_split_screen() -> void:
	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 0
	add_child(ui_layer)
	
	_ui_packages.resize(GameSettings.player_count)
	_ui_scores.resize(GameSettings.player_count)
	_ui_round_timers.resize(GameSettings.player_count)
	_ui_center_labels.resize(GameSettings.player_count)
	_ui_booted_labels.resize(GameSettings.player_count)
	_ui_items.resize(GameSettings.player_count)
	_ui_blind_screens.resize(GameSettings.player_count)
	_ui_item_menus.resize(GameSettings.player_count)
	_ui_blind_particles.resize(GameSettings.player_count)

	if GameSettings.is_online:
		# ── Online mode: single fullscreen viewport ─────────────────────────
		var container := SubViewportContainer.new()
		container.stretch = true
		container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ui_layer.add_child(container)

		var viewport := SubViewport.new()
		viewport.handle_input_locally = false
		viewport.canvas_cull_mask = 0xFFFFFFFF
		viewport.world_2d = get_viewport().world_2d
		viewport.transparent_bg = false
		viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		container.add_child(viewport)
		_add_glow_to_viewport(viewport)

		var cam := Camera2D.new()
		cam.set_script(load("res://scripts/camera_shake.gd"))
		cam.zoom = Vector2(0.25, 0.25)
		cam.name = "OnlineCamera"
		viewport.add_child(cam)

		# In online, we only have one viewport/camera for the local player,
		# but _cameras still needs entries for indexing consistency.
		_cameras.resize(GameSettings.player_count)
		_viewports.resize(GameSettings.player_count)
		_viewport_containers.resize(GameSettings.player_count)
		
		for p in range(GameSettings.player_count):
			if p == _local_player_idx:
				_cameras[p] = cam
				_viewports[p] = viewport
				_viewport_containers[p] = container
			else:
				_cameras[p] = null
				_viewports[p] = null
				_viewport_containers[p] = null

		# Build HUD only for the local player
		_build_player_hud(_local_player_idx)
	else:
		# ── Local mode: split-screen ──────────────────────────────────────────
		var hbox := HBoxContainer.new()
		hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hbox.add_theme_constant_override("separation", 4)
		ui_layer.add_child(hbox)

		for p in range(GameSettings.player_count):
			var container2 := SubViewportContainer.new()
			container2.stretch = true
			container2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			container2.size_flags_vertical = Control.SIZE_EXPAND_FILL
			hbox.add_child(container2)

			var viewport2 := SubViewport.new()
			viewport2.handle_input_locally = false
			viewport2.canvas_cull_mask = 0xFFFFFFFF
			viewport2.world_2d = get_viewport().world_2d
			viewport2.transparent_bg = false
			viewport2.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
			container2.add_child(viewport2)
			_add_glow_to_viewport(viewport2)

			var cam2 := Camera2D.new()
			cam2.set_script(load("res://scripts/camera_shake.gd"))
			cam2.zoom = Vector2(0.25, 0.25)
			cam2.name = "CamPlayer" + str(p + 1)
			viewport2.add_child(cam2)
			_cameras.append(cam2)

			_viewports.append(viewport2)
			_viewport_containers.append(container2)

			# Separator line between viewports (skip for last)
			if p < GameSettings.player_count - 1:
				var sep := ColorRect.new()
				sep.color = Color(0.2, 0.2, 0.3, 1.0)
				sep.custom_minimum_size = Vector2(4, 0)
				sep.size_flags_vertical = Control.SIZE_EXPAND_FILL
				hbox.add_child(sep)

		# Build per-player HUD overlays
		for p in range(GameSettings.player_count):
			_build_player_hud(p)

	# ── Global results screen overlay ─────────────────────────────────────────
	_global_results_screen = ColorRect.new()
	_global_results_screen.color = Color(0, 0, 0, 0.8)
	_global_results_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_global_results_screen.visible = false
	ui_layer.add_child(_global_results_screen)


func _add_glow_to_viewport(vp: SubViewport) -> void:
	vp.use_hdr_2d = true
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_strength = 0.9
	env.glow_bloom = 0.0 # Disabled so road stripes don't bloom
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN # Screen mode reduces flickering on some GPUs like Intel HD
	env.glow_hdr_threshold = 1.2 # slightly lower so headlights and cars bloom softly
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

func _build_player_hud(player_idx: int) -> void:
	var font = load("res://assets/Poppins-Medium.ttf") as Font

	var vp : SubViewport = _viewports[player_idx]
	if vp == null:
		return

	# Each player gets a CanvasLayer inside their SubViewport so the HUD
	# stays screen-fixed and doesn't move with the Camera2D.
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 5
	vp.add_child(hud_layer)

	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(hud)

	var player_color : Color = _player_colors[player_idx % 4]
	var minimap_key := "TAB"
	
	var s := 1.0
	if not GameSettings.is_online:
		minimap_key = "TAB" if player_idx == 0 else "R-CTRL"
		if GameSettings.player_count == 2:
			s = 0.75
		elif GameSettings.player_count >= 3:
			s = 0.5

	# ── UI Overhaul (Modern Panels) ─────────────────────────────────────────
	
	# Top-Left Panel (Player + Score)
	var tl_panel := PanelContainer.new()
	var tl_style := StyleBoxFlat.new()
	tl_style.bg_color = Color(0.05, 0.05, 0.1, 0.7)
	tl_style.border_color = player_color
	tl_style.set_border_width_all(int(3 * s) if int(3 * s) > 1 else 1)
	tl_style.set_corner_radius_all(int(16 * s))
	tl_style.set_content_margin_all(int(12 * s))
	tl_style.shadow_color = Color(0,0,0,0.5)
	tl_style.shadow_size = int(10 * s)
	tl_panel.add_theme_stylebox_override("panel", tl_style)
	tl_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tl_panel.offset_left = int(20 * s)
	tl_panel.offset_top = int(20 * s)
	hud.add_child(tl_panel)
	
	var tl_hbox := HBoxContainer.new()
	tl_hbox.add_theme_constant_override("separation", int(15 * s))
	tl_panel.add_child(tl_hbox)
	
	var p_label := Label.new()
	p_label.text = "P%d" % (player_idx + 1)
	if font != null: p_label.add_theme_font_override("font", font)
	p_label.add_theme_font_size_override("font_size", int(32 * s))
	p_label.add_theme_color_override("font_color", player_color)
	p_label.add_theme_color_override("font_outline_color", Color(0,0,0))
	p_label.add_theme_constant_override("outline_size", int(6 * s))
	tl_hbox.add_child(p_label)
	
	var score_label := Label.new()
	score_label.text = ""
	if font != null: score_label.add_theme_font_override("font", font)
	score_label.add_theme_font_size_override("font_size", int(28 * s))
	score_label.add_theme_color_override("font_color", Color("#fcee0a"))
	tl_hbox.add_child(score_label)
	_ui_scores[player_idx] = score_label
	
	# Top-Right Panel (Timer + Packages)
	var tr_panel := PanelContainer.new()
	var tr_style = tl_style.duplicate()
	tr_style.border_color = Color("#00f0ff")
	tr_panel.add_theme_stylebox_override("panel", tr_style)
	tr_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	tr_panel.offset_right = int(-20 * s)
	tr_panel.offset_top = int(20 * s)
	hud.add_child(tr_panel)
	
	var tr_hbox := HBoxContainer.new()
	tr_hbox.add_theme_constant_override("separation", int(20 * s))
	tr_panel.add_child(tr_hbox)
	
	var pkg_label := Label.new()
	pkg_label.text = ""
	if font != null: pkg_label.add_theme_font_override("font", font)
	pkg_label.add_theme_font_size_override("font_size", int(28 * s))
	pkg_label.add_theme_color_override("font_color", Color.WHITE)
	tr_hbox.add_child(pkg_label)
	_ui_packages[player_idx] = pkg_label
	
	var time_label := Label.new()
	time_label.text = "0:00"
	if font != null: time_label.add_theme_font_override("font", font)
	time_label.add_theme_font_size_override("font_size", int(32 * s))
	time_label.add_theme_color_override("font_color", Color("#ff003c"))
	tr_hbox.add_child(time_label)
	_ui_round_timers[player_idx] = time_label

	# Bottom-Left Panel (Items & Minimap)
	var bl_panel := PanelContainer.new()
	var bl_style = tl_style.duplicate()
	bl_style.border_color = Color("#ff003c")
	bl_panel.add_theme_stylebox_override("panel", bl_style)
	bl_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	bl_panel.offset_left = int(20 * s)
	bl_panel.offset_bottom = int(-20 * s)
	hud.add_child(bl_panel)
	
	var bl_vbox := VBoxContainer.new()
	bl_vbox.add_theme_constant_override("separation", int(5 * s))
	bl_panel.add_child(bl_vbox)
	
	var item_label := Label.new()
	item_label.text = "Item: None"
	if font != null: item_label.add_theme_font_override("font", font)
	item_label.add_theme_font_size_override("font_size", int(24 * s))
	item_label.add_theme_color_override("font_color", Color("#00f0ff"))
	bl_vbox.add_child(item_label)
	_ui_items[player_idx] = item_label
	
	var mm_hint := Label.new()
	mm_hint.text = minimap_key + " = Map"
	if font != null: mm_hint.add_theme_font_override("font", font)
	mm_hint.add_theme_font_size_override("font_size", int(16 * s))
	mm_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	bl_vbox.add_child(mm_hint)
	
	# Booted Label (Center Screen)
	var booted_lbl := Label.new()
	booted_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	booted_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	booted_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	booted_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	booted_lbl.grow_vertical = Control.GROW_DIRECTION_BOTH
	booted_lbl.offset_top = int(150 * s) # Slightly below true center
	if font != null: booted_lbl.add_theme_font_override("font", font)
	booted_lbl.add_theme_font_size_override("font_size", int(84 * s))
	booted_lbl.add_theme_color_override("font_color", Color("#ff003c"))
	booted_lbl.add_theme_color_override("font_outline_color", Color(0,0,0))
	booted_lbl.add_theme_constant_override("outline_size", 10)
	hud.add_child(booted_lbl)
	_ui_booted_labels[player_idx] = booted_lbl

	# ── Center screen messages (countdown) ──────────────────────────────────
	var center_lbl := Label.new()
	center_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	center_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center_lbl.grow_vertical = Control.GROW_DIRECTION_BOTH
	center_lbl.text = ""
	if font != null:
		center_lbl.add_theme_font_override("font", font)
	center_lbl.add_theme_font_size_override("font_size", int(120 * s))
	center_lbl.add_theme_color_override("font_color", Color("#fcee0a"))
	center_lbl.add_theme_color_override("font_outline_color", Color("#ff003c"))
	center_lbl.add_theme_constant_override("outline_size", 8)
	hud.add_child(center_lbl)
	_ui_center_labels[player_idx] = center_lbl

	# ── Target Indicators ────────────────────────────────────────────────────
	var indicator_script := load("res://scripts/target_indicators.gd") as Script
	if indicator_script != null:
		var indicator := Control.new()
		indicator.set_script(indicator_script)
		indicator.player_idx = player_idx
		indicator.main_ref = self
		indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hud.add_child(indicator)
		hud.move_child(indicator, 0)

	# ── Blind Screen (Peanuts) ───────────────────────────────────────────────
	var blind_screen := ColorRect.new()
	blind_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blind_screen.color = Color(1.0, 1.0, 1.0, 0.0) # fully transparent initially
	blind_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(blind_screen)
	_ui_blind_screens[player_idx] = blind_screen

	var peanuts := CPUParticles2D.new()
	peanuts.amount = 150
	peanuts.lifetime = 2.0
	peanuts.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	peanuts.emission_rect_extents = Vector2(4000, 20)
	peanuts.position = Vector2(0, 0)
	peanuts.direction = Vector2(0, 1)
	peanuts.spread = 15.0
	peanuts.initial_velocity_min = 400.0
	peanuts.initial_velocity_max = 800.0
	peanuts.scale_amount_min = 10.0
	peanuts.scale_amount_max = 25.0
	peanuts.color = Color(0.9, 0.8, 0.6)
	peanuts.emitting = false
	
	var peanut_anchor := Control.new()
	peanut_anchor.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	blind_screen.add_child(peanut_anchor)
	peanut_anchor.add_child(peanuts)
	_ui_blind_particles[player_idx] = peanuts

	# ── Item Choice Menu ───────────────────────────────────────────────
	var item_menu := PanelContainer.new()
	item_menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	item_menu.visible = false
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.9)
	style.border_width_left = 4
	style.border_width_right = 4
	style.border_width_top = 4
	style.border_width_bottom = 4
	style.border_color = Color(1, 0.8, 0.2)
	item_menu.add_theme_stylebox_override("panel", style)
	
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 15)
	
	var title := Label.new()
	title.text = "CHOOSE YOUR ITEM\n(Steer: Select, Space: Confirm)"
	if not GameSettings.is_online and player_idx == 1:
		title.text = "CHOOSE YOUR ITEM\n(Steer: Select, /: Confirm)"
	if font != null:
		title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	
	var options_vbox := VBoxContainer.new()
	item_menu.set_meta("options", options_vbox)
	for i in range(ITEM_NAMES.size()):
		var lbl := Label.new()
		lbl.text = ITEM_NAMES[i]
		if font != null:
			lbl.add_theme_font_override("font", font)
		lbl.add_theme_font_size_override("font_size", 32)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		options_vbox.add_child(lbl)
	vbox.add_child(options_vbox)
	
	item_menu.add_child(vbox)
	hud.add_child(item_menu)
	_ui_item_menus[player_idx] = item_menu


func _process(delta: float) -> void:
	_process_game_state(delta)

	# Process blind timers
	for p in range(GameSettings.player_count):
		if _blind_timers[p] > 0.0:
			_blind_timers[p] -= delta
			var alpha = minf(1.0, _blind_timers[p] / 1.0) # fade out over last second
			if _ui_blind_screens[p] != null:
				_ui_blind_screens[p].color = Color(1.0, 1.0, 1.0, alpha * 0.8)
			if _blind_timers[p] <= 0.0:
				if _ui_blind_particles[p] != null:
					_ui_blind_particles[p].emitting = false
				if _ui_blind_screens[p] != null:
					_ui_blind_screens[p].color = Color(1.0, 1.0, 1.0, 0.0)

		# Process boot timers & cop cooldown
		if _boot_timers[p] > 0.0:
			_boot_timers[p] -= delta
			if _cars[p] != null:
				_cars[p].frozen = true
			if _boot_timers[p] <= 0.0 and _cars[p] != null:
				if _game_state == "playing":
					_cars[p].frozen = false
			_update_ui(p)

		if _cop_cooldown[p] > 0.0:
			_cop_cooldown[p] -= delta

	# Process oil spills
	var players_to_process = [_local_player_idx] if GameSettings.is_online else range(GameSettings.player_count)
	for p in players_to_process:
		if p >= _cars.size() or _cars[p] == null: continue
		var on_oil = false
		var oil_type = 0
		var hit_spill = null
		for spill in _oil_spills:
			if spill["owner"] != p and _cars[p].global_position.distance_to(spill["pos"]) < 120.0:
				on_oil = true
				oil_type = spill["type"]
				hit_spill = spill
				break
		if on_oil and not _cars[p].frozen:
			if oil_type == 1: # Slippery Oil - Extreme spinout
				if _cars[p].has_method("trigger_spinout"):
					_cars[p].trigger_spinout()
				if is_instance_valid(hit_spill["node"]):
					hit_spill["node"].queue_free()
				_oil_spills.erase(hit_spill)
			elif oil_type == 2: # Sticky Oil - Extreme slowdown
				_cars[p].velocity *= 0.85
				_cars[p].rotation += sin(Time.get_ticks_msec()/20.0) * 0.5 * delta

	# Update cameras to follow cars
	for p in range(GameSettings.player_count):
		if p < _cars.size() and _cars[p] != null and p < _cameras.size() and _cameras[p] != null:
			var cam_pos = _cars[p].global_position
			if p < _camera_trauma.size() and _camera_trauma[p] > 0.0:
				var trauma_sq = _camera_trauma[p] * _camera_trauma[p]
				cam_pos += Vector2(randf_range(-1, 1), randf_range(-1, 1)) * trauma_sq * 50.0
				_camera_trauma[p] = maxf(0.0, _camera_trauma[p] - delta * 0.5)
			_cameras[p].global_position = cam_pos

	# ── Network car sync ────────────────────────────────────────────────────
	if GameSettings.is_online:
		var local_car := _cars[_local_player_idx] if _local_player_idx < _cars.size() else null
		if local_car != null:
			_rpc_car_sync.rpc(_local_player_idx, local_car.position.x, local_car.position.y,
				local_car.rotation, local_car.velocity.x, local_car.velocity.y,
				local_car.steer_direction)

	if _game_state != "playing":
		return

	# Respawn NPCs if any despawned
	_npcs = _npcs.filter(func(n): return is_instance_valid(n) and not n.is_queued_for_deletion())
	if _npcs.size() < 25:
		_spawn_one_npc()

	# Process Cops
	_cops = _cops.filter(func(c): return is_instance_valid(c) and not c.is_queued_for_deletion())
	while _cops.size() < 4:
		_spawn_one_cop()
		
	for cop in _cops:
		var target = null
		var closest_dist = 9999999.0
		for p in range(GameSettings.player_count):
			if _player_wanted[p] and _cars[p] != null:
				var dist = cop.global_position.distance_to(_cars[p].global_position)
				if dist < closest_dist:
					closest_dist = dist
					target = _cars[p]
		cop.target_player = target

	# Per-player game logic
	var players_to_check : Array[int] = []
	if GameSettings.is_online:
		# In online mode, only process logic for the local player
		players_to_check = [_local_player_idx]
	else:
		players_to_check = []
		for p in range(GameSettings.player_count):
			players_to_check.append(p)

	for p in players_to_check:
		if p >= _cars.size() or _cars[p] == null:
			continue

		var car_pos := _cars[p].global_position
		var speed : float = 0.0
		if "velocity" in _cars[p]:
			speed = _cars[p].velocity.length()

		var at_po = (_post_office != null and car_pos.distance_to(_post_office.global_position) < 2000.0)

		# Check Shop & Items
		if _player_item_cooldown[p] > 0.0:
			_player_item_cooldown[p] -= delta
			if _player_item_cooldown[p] <= 0.0:
				_player_item_cooldown[p] = 0.0
			_update_ui(p)

		var is_shopping = (_ui_item_menus[p] != null and _ui_item_menus[p].visible)

		var shop_action = "p1_shop" if GameSettings.is_online else "p%d_shop" % (p + 1)
		var right_action = "p1_steer_right" if GameSettings.is_online else "p%d_steer_right" % (p + 1)
		var left_action = "p1_steer_left" if GameSettings.is_online else "p%d_steer_left" % (p + 1)

		if Input.is_action_just_pressed(shop_action):
			if at_po and not _player_item_locked[p] and _player_scores[p] >= 5:
				if not is_shopping:
					# Open menu
					if _ui_item_menus[p] != null:
						_ui_item_menus[p].visible = true
					_cars[p].frozen = true
				else:
					# Confirm choice
					_player_item_locked[p] = true
					_player_has_item[p] = true
					_player_item_cooldown[p] = 0.0
					if _ui_item_menus[p] != null:
						_ui_item_menus[p].visible = false
					_cars[p].frozen = false
					_update_ui(p)
			elif _player_has_item[p] and _player_item_cooldown[p] <= 0.0:
				_player_item_cooldown[p] = 60.0
				_use_item(p, _player_selected_item[p])
				_update_ui(p)

		# If shopping, cycle with steer left/right
		if is_shopping:
			if Input.is_action_just_pressed(right_action):
				_player_selected_item[p] = (_player_selected_item[p] + 1) % ITEM_NAMES.size()
				_update_ui(p)
			elif Input.is_action_just_pressed(left_action):
				_player_selected_item[p] = (_player_selected_item[p] - 1 + ITEM_NAMES.size()) % ITEM_NAMES.size()
				_update_ui(p)
			# Close shop if they somehow leave PO
			if not at_po:
				_ui_item_menus[p].visible = false
				_cars[p].frozen = false

		# Check Post Office (pickup — no box thrown)
		if _post_office != null and _player_packages[p] == 0 and speed < 400.0:
			if car_pos.distance_to(_post_office.global_position) < 2000.0:
				_player_packages[p] = 5
				_assign_random_deliveries(p)
				_update_ui(p)
				if GameSettings.is_online:
					# Send package pickup to the other player
					var target_indices : Array[int] = []
					for t in _player_targets[p]:
						var idx := _houses.find(t)
						if idx >= 0:
							target_indices.append(idx)
					_rpc_pickup_packages.rpc(p, target_indices)

		# Check Houses — throw a box instead of instant delivery
		if _player_packages[p] > 0 and speed < 400.0:
			var targets : Array = _player_targets[p]
			for i in range(targets.size() - 1, -1, -1):
				var h : Sprite2D = targets[i]
				if car_pos.distance_to(h.global_position) < 2000.0:
					# Only throw if we haven't already thrown at this house
					var already_thrown := false
					for b in _thrown_boxes:
						if b["target"] == h:
							already_thrown = true
							break
					if already_thrown:
						continue
					_throw_box_at(h, p)
					_player_packages[p] -= 1
					targets.remove_at(i)
					_update_ui(p)
					break

	# Animate thrown boxes
	_update_thrown_boxes(delta)


func _process_game_state(_delta_unused: float) -> void:
	var now := Time.get_ticks_msec()
	var real_delta := (now - _last_tick) / 1000.0
	_last_tick = now

	if _game_state == "countdown":
		var old_sec := int(ceil(_countdown_timer))
		_countdown_timer -= real_delta
		var new_sec := int(ceil(_countdown_timer))

		if _countdown_timer <= 0.0:
			_game_state = "playing"
			for lbl in _ui_center_labels:
				if lbl == null: continue
				lbl.text = "GO!"
				lbl.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
			for car in _cars:
				if car != null:
					car.frozen = false

			# Fade out "GO!" after 1 second
			var tw := create_tween()
			for lbl in _ui_center_labels:
				if lbl == null: continue
				tw.tween_property(lbl, "modulate:a", 0.0, 1.0)
		else:
			for lbl in _ui_center_labels:
				if lbl == null: continue
				lbl.text = str(new_sec)

	elif _game_state == "playing":
		_round_timer -= real_delta
		if _round_timer <= 0.0:
			_round_timer = 0.0
			_end_game()

		# Update UI timers
		var m := int(_round_timer) / 60
		var s := int(_round_timer) % 60
		var time_str := "%d:%02d" % [m, s]
		for lbl in _ui_round_timers:
			if lbl == null: continue
			lbl.text = time_str
			if _round_timer <= 10.0:
				lbl.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))


func _end_game() -> void:
	_game_state = "finished"
	for car in _cars:
		if car != null:
			car.frozen = true

	# Determine winner
	var max_score = -1
	var winners = []
	for p in range(GameSettings.player_count):
		if _player_scores[p] > max_score:
			max_score = _player_scores[p]
			winners = [p]
		elif _player_scores[p] == max_score:
			winners.append(p)

	var win_text := ""
	var win_color := Color.WHITE

	if winners.size() == 1:
		win_text = "PLAYER %d WINS!\nScore: %d" % [winners[0] + 1, max_score]
		win_color = _player_colors[winners[0] % 4]
	else:
		win_text = "IT'S A TIE!\nScore: %d" % max_score
		win_color = Color(1, 0.9, 0.5)

	# Show global results screen
	_global_results_screen.visible = true

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 30)
	_global_results_screen.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "TIME'S UP!"
	var font = load("res://assets/Poppins-Medium.ttf") as Font
	if font != null:
		lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", 80)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	var win_lbl := Label.new()
	win_lbl.text = win_text
	if font != null:
		win_lbl.add_theme_font_override("font", font)
	win_lbl.add_theme_font_size_override("font_size", 56)
	win_lbl.add_theme_color_override("font_color", win_color)
	win_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(win_lbl)

	var btn := Button.new()
	btn.text = "MAIN MENU"
	btn.custom_minimum_size = Vector2(300, 60)
	if font != null:
		btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 28)
	btn.pressed.connect(func() -> void:
		if GameSettings.is_online:
			NetworkManager.disconnect_game()
			GameSettings.reset_network()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	vbox.add_child(btn)

	# Make sure mouse is visible again since we need to click
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# In online mode, sync end game to remote
	if GameSettings.is_online and GameSettings.is_host:
		_rpc_end_game.rpc(_player_scores)


# ══════════════════════════════════════════════════════════════════════════════
#  Network RPCs
# ══════════════════════════════════════════════════════════════════════════════

## Receive car position/rotation/velocity from the remote player.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_car_sync(p_idx: int, px: float, py: float, rot: float, vx: float, vy: float, steer: float) -> void:
	if p_idx >= 0 and p_idx < _cars.size() and _cars[p_idx] != null:
		_cars[p_idx].apply_sync(Vector2(px, py), rot, Vector2(vx, vy), steer)


## Remote player picked up packages — sync their targets to our UI.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_pickup_packages(player_idx: int, house_indices: Array) -> void:
	if player_idx >= 0 and player_idx < GameSettings.player_count:
		_player_packages[player_idx] = 5
		_player_targets[player_idx].clear()
		for idx in house_indices:
			if idx >= 0 and idx < _houses.size():
				_player_targets[player_idx].append(_houses[idx])
		_update_ui(player_idx)


## Remote player delivered a package — update our local score.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_deliver_package(player_idx: int, new_score: int) -> void:
	if player_idx >= 0 and player_idx < GameSettings.player_count:
		_player_scores[player_idx] = new_score
		_player_packages[player_idx] = maxi(_player_packages[player_idx] - 1, 0)
		_update_ui(player_idx)


## Remote side says game is over.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_end_game(scores: Array) -> void:
	for i in range(min(scores.size(), GameSettings.player_count)):
		_player_scores[i] = scores[i]
	if _game_state != "finished":
		_end_game()


func _use_item(user_idx: int, item_type: int) -> void:
	if GameSettings.is_online:
		_rpc_use_item.rpc(user_idx, item_type)
	if item_type == 0:
		_trigger_blind(user_idx)
	elif item_type == 1 or item_type == 2:
		_spawn_oil_spill(user_idx, item_type)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_use_item(user_idx: int, item_type: int) -> void:
	if item_type == 0:
		_trigger_blind(user_idx)
	elif item_type == 1 or item_type == 2:
		_spawn_oil_spill(user_idx, item_type)


func _trigger_blind(user_idx: int) -> void:
	for p in range(GameSettings.player_count):
		if p != user_idx:
			_blind_timers[p] = 4.0  # Increased to 4 seconds
			if p < _camera_trauma.size():
				_camera_trauma[p] = 1.0 # Screen shake
			if p < _ui_blind_particles.size() and _ui_blind_particles[p] != null:
				_ui_blind_particles[p].amount = 300 # More particles!
				_ui_blind_particles[p].emitting = true
				_ui_blind_particles[p].restart()


func _spawn_oil_spill(user_idx: int, type: int) -> void:
	if _cars[user_idx] == null: return
	var spill_pos = _cars[user_idx].global_position
	
	var spill = Sprite2D.new()
	if type == 1:
		spill.texture = load("res://assets/oil_spill_1.svg")
	else:
		spill.texture = load("res://assets/oil_spill_3.svg")
		
	# Start tiny for a pop-in effect
	spill.scale = Vector2(0.1, 0.1) 
	spill.global_position = spill_pos
	spill.z_index = 0
	add_child(spill)
	
	# Bounce scale animation
	var tween = create_tween().set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(spill, "scale", Vector2(0.8, 0.8), 0.8)
	
	_oil_spills.append({"pos": spill_pos, "type": type, "owner": user_idx, "node": spill})


func report_npc_crash(player_idx: int, pos: Vector2) -> void:
	if _cop_cooldown[player_idx] <= 0.0:
		_cop_cooldown[player_idx] = 10.0 # More consistent
		if not _player_wanted[player_idx]:
			_player_wanted[player_idx] = true
			if GameSettings.is_online:
				_rpc_set_wanted.rpc(player_idx, true)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_wanted(player_idx: int, wanted: bool) -> void:
	if player_idx >= 0 and player_idx < _player_wanted.size():
		_player_wanted[player_idx] = wanted


func boot_player(player_node: Node2D) -> void:
	var idx = _cars.find(player_node)
	if idx >= 0:
		_boot_timers[idx] = 10.0
		_player_wanted[idx] = false
		if GameSettings.is_online:
			_rpc_set_wanted.rpc(idx, false)
			_rpc_boot_player.rpc(idx)
		_update_ui(idx)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_boot_player(player_idx: int) -> void:
	if player_idx >= 0 and player_idx < _boot_timers.size():
		_boot_timers[player_idx] = 10.0
		_player_wanted[player_idx] = false
		_update_ui(player_idx)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if GameSettings.is_online:
			NetworkManager.disconnect_game()
			GameSettings.reset_network()


func _assign_random_deliveries(player_idx: int) -> void:
	_player_targets[player_idx].clear()

	var available := _houses.duplicate()
	available.shuffle()

	# Exclude houses already targeted by the other player
	var other := 1 - player_idx
	var other_targets : Array = _player_targets[other]

	for h in available:
		if _player_targets[player_idx].size() >= 5:
			break

		if h in other_targets:
			continue

		var ok := true
		for t in _player_targets[player_idx]:
			if h.global_position.distance_to(t.global_position) < 2500.0:
				ok = false
				break

		if ok:
			_player_targets[player_idx].append(h)

	for h in available:
		if _player_targets[player_idx].size() >= 5:
			break
		if not h in _player_targets[player_idx] and not h in other_targets:
			_player_targets[player_idx].append(h)


# ── Box throwing ──────────────────────────────────────────────────────────────

func _throw_box_at(house: Sprite2D, player_idx: int) -> void:
	if _box_tex == null:
		# Fallback: instant delivery if texture missing
		_player_scores[player_idx] += 1
		_update_ui(player_idx)
		return

	var car := _cars[player_idx]
	var box_sprite := Sprite2D.new()
	box_sprite.texture = _box_tex
	box_sprite.scale = Vector2(BOX_SCALE, BOX_SCALE)
	box_sprite.z_index = 10  # draw above everything
	box_sprite.position = car.global_position
	add_child(box_sprite)

	var dir_to_house := (car.global_position.direction_to(house.global_position))

	_thrown_boxes.append({
		"sprite": box_sprite,
		"target": house,
		"direction": dir_to_house,
		"phase": "flying",     # flying -> bouncing -> lingering -> done
		"bounce_timer": 0.0,
		"linger_timer": 0.0,
		"bounce_start": Vector2.ZERO,
		"bounce_end": Vector2.ZERO,
		"player_idx": player_idx,
	})


func _update_thrown_boxes(delta: float) -> void:
	var to_remove : Array[int] = []

	for i in range(_thrown_boxes.size()):
		var b : Dictionary = _thrown_boxes[i]
		var sprite : Sprite2D = b["sprite"]
		var house  : Sprite2D = b["target"]
		var pidx   : int      = b["player_idx"]

		if b["phase"] == "flying":
			# Move toward the house
			var move_dir : Vector2 = sprite.position.direction_to(house.global_position)
			sprite.position += move_dir * BOX_SPEED * delta
			# Spin the box while flying
			sprite.rotation += 8.0 * delta

			# Check collision
			if sprite.position.distance_to(house.global_position) < BOX_HIT_DIST:
				# Hit! Start bounce
				b["phase"] = "bouncing"
				b["bounce_timer"] = 0.0
				b["bounce_start"] = sprite.position
				# Bounce direction: away from the house
				var bounce_dir := house.global_position.direction_to(sprite.position)
				if bounce_dir.length_squared() < 0.01:
					bounce_dir = Vector2.UP
				b["bounce_end"] = sprite.position + bounce_dir * BOX_BOUNCE_DIST
				_player_scores[pidx] += 1
				_update_ui(pidx)
				
				if GameSettings.is_online and pidx == _local_player_idx:
					_rpc_deliver_package.rpc(pidx, _player_scores[pidx])

		elif b["phase"] == "bouncing":
			b["bounce_timer"] += delta
			var t := clampf(b["bounce_timer"] / BOX_BOUNCE_TIME, 0.0, 1.0)
			# Ease-out for a natural bounce feel
			var eased := 1.0 - (1.0 - t) * (1.0 - t)
			sprite.position = b["bounce_start"].lerp(b["bounce_end"], eased)
			# Slow down spin during bounce
			sprite.rotation += 4.0 * (1.0 - t) * delta
			# Shrink slightly during bounce
			var bounce_scale := lerpf(BOX_SCALE, BOX_SCALE * 0.7, eased)
			sprite.scale = Vector2(bounce_scale, bounce_scale)

			if t >= 1.0:
				b["phase"] = "lingering"
				b["linger_timer"] = 0.0

		elif b["phase"] == "lingering":
			b["linger_timer"] += delta
			# Fade out
			var fade := 1.0 - clampf(b["linger_timer"] / BOX_LINGER_TIME, 0.0, 1.0)
			sprite.modulate.a = fade

			if b["linger_timer"] >= BOX_LINGER_TIME:
				b["phase"] = "done"
				sprite.queue_free()
				to_remove.append(i)

	# Remove finished boxes (iterate in reverse to keep indices valid)
	for i in range(to_remove.size() - 1, -1, -1):
		_thrown_boxes.remove_at(to_remove[i])


func _update_ui(player_idx: int) -> void:
	if player_idx < _ui_packages.size() and _ui_packages[player_idx] != null:
		if _player_packages[player_idx] == 0:
			_ui_packages[player_idx].text = "Packages: 0 — Go to Post Office!"
		else:
			_ui_packages[player_idx].text = "Packages: " + str(_player_packages[player_idx])
	if player_idx < _ui_scores.size() and _ui_scores[player_idx] != null:
		_ui_scores[player_idx].text = "Score: " + str(_player_scores[player_idx])
	if player_idx < _ui_items.size() and _ui_items[player_idx] != null:
		var item_name = ITEM_NAMES[_player_selected_item[player_idx]]
		if _boot_timers[player_idx] > 0.0:
			if player_idx < _ui_booted_labels.size() and _ui_booted_labels[player_idx] != null:
				_ui_booted_labels[player_idx].text = "BOOTED! %ds" % int(ceil(_boot_timers[player_idx]))
		else:
			if player_idx < _ui_booted_labels.size() and _ui_booted_labels[player_idx] != null:
				_ui_booted_labels[player_idx].text = ""

		if not _player_item_locked[player_idx]:
			var is_shopping = (_ui_item_menus[player_idx] != null and _ui_item_menus[player_idx].visible)
			if is_shopping:
				_ui_items[player_idx].text = "Select Item: " + item_name + " (Space: Confirm)"
			else:
				if _player_scores[player_idx] >= 5:
					_ui_items[player_idx].text = "Press Space at PO to open Shop!"
				else:
					_ui_items[player_idx].text = "Shop Unlocks at 5 Points!"
		elif not _player_has_item[player_idx]:
			_ui_items[player_idx].text = "Item: " + item_name + " (Empty)"
		elif _player_item_cooldown[player_idx] > 0.0:
			_ui_items[player_idx].text = "Item: %ds" % int(ceil(_player_item_cooldown[player_idx]))
		else:
			_ui_items[player_idx].text = "Item: " + item_name + " [READY]"

	if player_idx < _ui_item_menus.size() and _ui_item_menus[player_idx] != null:
		var opts = _ui_item_menus[player_idx].get_meta("options")
		for i in range(opts.get_child_count()):
			var lbl = opts.get_child(i) as Label
			if i == _player_selected_item[player_idx]:
				lbl.add_theme_color_override("font_color", Color(0.2, 1.0, 0.2))
				lbl.text = "> " + ITEM_NAMES[i] + " <"
			else:
				lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
				lbl.text = ITEM_NAMES[i]


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if GameSettings.is_online:
			# Online: Tab toggles the local player's minimap
			if event.physical_keycode == KEY_TAB:
				if _local_player_idx < _minimaps.size() and _minimaps[_local_player_idx] != null:
					_minimaps[_local_player_idx].visible = not _minimaps[_local_player_idx].visible
				get_viewport().set_input_as_handled()
		else:
			# Local: P1 = Tab, P2 = R-CTRL
			if event.physical_keycode == KEY_TAB:
				if _minimaps.size() > 0:
					_minimaps[0].visible = not _minimaps[0].visible
				get_viewport().set_input_as_handled()
			elif event.physical_keycode == KEY_CTRL and event.location == KEY_LOCATION_RIGHT:
				if _minimaps.size() > 1:
					_minimaps[1].visible = not _minimaps[1].visible
				get_viewport().set_input_as_handled()


# ── Scene measurement ─────────────────────────────────────────────────────────

func _find_first_sprite(node: Node) -> Sprite2D:
	if node is Sprite2D:
		return node as Sprite2D
	for child in node.get_children():
		var found := _find_first_sprite(child)
		if found != null:
			return found
	return null


func _measure_scenes() -> void:
	var road_inst := straight_road_scene.instantiate()
	var road_sprite := _find_first_sprite(road_inst)
	if road_sprite != null and road_sprite.texture != null:
		var sz : Vector2 = road_sprite.texture.get_size()
		_road_width  = sz.x * abs(road_sprite.scale.x)
		_road_length = sz.y * abs(road_sprite.scale.y)
	road_inst.free()

	var inter_inst := four_way_scene.instantiate()
	var inter_sprite := _find_first_sprite(inter_inst)
	if inter_sprite != null and inter_sprite.texture != null:
		var sz : Vector2 = inter_sprite.texture.get_size()
		_inter_size = sz.x * abs(inter_sprite.scale.x)
	inter_inst.free()

	_cell_size = _road_length + _inter_size


# ── Coordinate helpers ────────────────────────────────────────────────────────

func _world_pos(col: float, row: float) -> Vector2:
	var offset_x := (grid_cols * _cell_size) / 2.0
	var offset_y := (grid_rows * _cell_size) / 2.0
	return Vector2(col * _cell_size - offset_x, row * _cell_size - offset_y)


# ── Segment arrays ────────────────────────────────────────────────────────────

func _init_segment_arrays() -> void:
	_h_segs = []
	for r in range(grid_rows + 1):
		var row_arr : Array = []
		for c in range(grid_cols):
			if r == 0 or r == grid_rows:
				row_arr.append(true)
			else:
				row_arr.append(_rng.randf() < road_density)
		_h_segs.append(row_arr)

	_v_segs = []
	for r in range(grid_rows):
		var row_arr : Array = []
		for c in range(grid_cols + 1):
			if c == 0 or c == grid_cols:
				row_arr.append(true)
			else:
				row_arr.append(_rng.randf() < road_density)
		_v_segs.append(row_arr)


## Count how many road segments connect to the node at grid position (c, r).
func _node_degree(c: int, r: int) -> int:
	var deg := 0
	if r > 0          and _v_segs[r - 1][c]: deg += 1  # north
	if r < grid_rows  and _v_segs[r][c]:     deg += 1  # south
	if c < grid_cols  and _h_segs[r][c]:     deg += 1  # east
	if c > 0          and _h_segs[r][c - 1]: deg += 1  # west
	return deg


## Iteratively remove road segments that lead to dead-end nodes (degree == 1).
## Keeps pruning until no more dead-ends exist, since removing a segment can
## create a new dead-end at the other end.
func _prune_dead_ends() -> void:
	var changed := true
	while changed:
		changed = false
		# Check every node in the grid
		for r in range(grid_rows + 1):
			for c in range(grid_cols + 1):
				if _node_degree(c, r) != 1:
					continue
				# This node is a dead-end — remove its single segment
				if r > 0          and _v_segs[r - 1][c]:
					_v_segs[r - 1][c] = false
				elif r < grid_rows and _v_segs[r][c]:
					_v_segs[r][c] = false
				elif c < grid_cols and _h_segs[r][c]:
					_h_segs[r][c] = false
				elif c > 0         and _h_segs[r][c - 1]:
					_h_segs[r][c - 1] = false
				changed = true


# ── Road placement ────────────────────────────────────────────────────────────

func _place_roads() -> void:
	for r in range(grid_rows + 1):
		for c in range(grid_cols):
			if _h_segs[r][c]:
				_place_horizontal_road(r, c)

	for r in range(grid_rows):
		for c in range(grid_cols + 1):
			if _v_segs[r][c]:
				_place_vertical_road(r, c)

	for r in range(grid_rows + 1):
		for c in range(grid_cols + 1):
			_place_intersection(r, c)  # skips nodes with < 2 roads internally


func _place_horizontal_road(r: int, c: int) -> void:
	var road := straight_road_scene.instantiate()
	add_child(road)
	road.rotation = PI / 2.0
	road.position = _world_pos(c + 0.5, r)


func _place_vertical_road(r: int, c: int) -> void:
	var road := straight_road_scene.instantiate()
	add_child(road)
	road.position = _world_pos(c, r + 0.5)


func _place_intersection(r: int, c: int) -> void:
	# Which of the four cardinal roads connect to this node?
	var has_n : bool = r > 0          and _v_segs[r - 1][c]
	var has_s : bool = r < grid_rows  and _v_segs[r][c]
	var has_e : bool = c < grid_cols  and _h_segs[r][c]
	var has_w : bool = c > 0          and _h_segs[r][c - 1]
	var count := int(has_n) + int(has_s) + int(has_e) + int(has_w)

	if count == 0:
		return

	# Dead-end cap: base sprite has road exiting NORTH, cap at SOUTH.
	if count == 1:
		var cap_angle : float
		if   has_n: cap_angle = 0.0        # exit north, cap south
		elif has_e: cap_angle = PI / 2.0   # exit east,  cap west
		elif has_s: cap_angle = PI         # exit south, cap north
		else:       cap_angle = -PI / 2.0  # exit west,  cap east
		var cap := straight_inter_scene.instantiate()
		cap.position = _world_pos(c, r)
		cap.rotation = cap_angle
		add_child(cap)
		return

	var scene  : PackedScene
	var angle  : float = 0.0

	if count == 4:
		scene = four_way_scene

	elif count == 3:
		# Base sprite is missing NORTH.  Rotate to whichever side is missing.
		scene = three_way_scene
		if   not has_n: angle = 0.0
		elif not has_e: angle = PI / 2.0
		elif not has_s: angle = PI
		else:           angle = -PI / 2.0   # missing west

	else:  # count == 2
		if (has_n and has_s) or (has_e and has_w):
			# Straight-through node.
			scene = straight_inter_scene
			angle = 0.0 if (has_n and has_s) else PI / 2.0
		else:
			# Corner.  Base sprite exits SOUTH + WEST.
			scene = l_corner_scene
			if   has_s and has_w: angle = 0.0
			elif has_n and has_w: angle = PI / 2.0
			elif has_n and has_e: angle = PI
			else:                 angle = -PI / 2.0  # south + east

	var inter := scene.instantiate()
	inter.position = _world_pos(c, r)
	inter.rotation = angle
	add_child(inter)


# ── House placement ───────────────────────────────────────────────────────────
# Houses are placed on BOTH sides of every road segment (no enclosed-block
# requirement), so the whole city gets populated.

func _place_houses() -> void:
	var tex : Texture2D = load(HOUSE_TEXTURE_PATH)
	if tex == null:
		push_error("Could not load house texture: " + HOUSE_TEXTURE_PATH)
		return

	var from_road  := _road_width * 0.5 + CURB_OFFSET
	var end_margin := _inter_size * 0.2

	# ── Horizontal segments → houses on south and north sides ─────────────────
	for r in range(grid_rows + 1):
		for c in range(grid_cols):
			if not _h_segs[r][c]:
				continue
			var road_y : float = _world_pos(0.0, float(r)).y
			var x0 : float = _world_pos(float(c),     float(r)).x + _inter_size * 0.5 + end_margin
			var x1 : float = _world_pos(float(c + 1), float(r)).x - _inter_size * 0.5 - end_margin
			_place_curb_houses(tex, x0, x1, road_y + from_road, 0.0)  # south side
			_place_curb_houses(tex, x0, x1, road_y - from_road, PI)   # north side

	# ── Vertical segments → houses on east and west sides ─────────────────────
	for r in range(grid_rows):
		for c in range(grid_cols + 1):
			if not _v_segs[r][c]:
				continue
			var road_x : float = _world_pos(float(c), 0.0).x
			var y0 : float = _world_pos(float(c), float(r)).y     + _inter_size * 0.5 + end_margin
			var y1 : float = _world_pos(float(c), float(r + 1)).y - _inter_size * 0.5 - end_margin
			_place_curb_houses_v(tex, road_x + from_road, y0, y1, -PI * 0.5)  # east side
			_place_curb_houses_v(tex, road_x - from_road, y0, y1,  PI * 0.5)  # west side

	if _post_office == null and _houses.size() > 0:
		var po_idx = _rng.randi_range(0, _houses.size() - 1)
		_post_office = _houses[po_idx]
		_houses.remove_at(po_idx)
		
		var po_tex = load("res://assets/post_office.svg")
		if po_tex != null:
			_post_office.texture = po_tex
		_post_office.modulate = Color.WHITE
		_post_office.scale = Vector2(HOUSE_SCALE, HOUSE_SCALE)


## Place `houses_per_side` houses evenly spaced along a horizontal curb strip.
## `facing_angle` is the sprite rotation so the house faces the road.
func _place_curb_houses(tex: Texture2D, x0: float, x1: float, y: float, facing_angle: float) -> void:
	if x1 <= x0:
		return
	for i in range(houses_per_side):
		var t : float = (i + 0.5) / float(houses_per_side)
		var x : float = lerp(x0, x1, t)
		_spawn_house(tex, Vector2(x, y), facing_angle)


## Same but along a vertical curb strip.
func _place_curb_houses_v(tex: Texture2D, x: float, y0: float, y1: float, facing_angle: float) -> void:
	if y1 <= y0:
		return
	for i in range(houses_per_side):
		var t : float = (i + 0.5) / float(houses_per_side)
		var y : float = lerp(y0, y1, t)
		_spawn_house(tex, Vector2(x, y), facing_angle)


func _spawn_house(tex: Texture2D, pos: Vector2, angle: float) -> void:
	var sprite := Sprite2D.new()
	sprite.scale   = Vector2(HOUSE_SCALE, HOUSE_SCALE)
	
	# The original texture is drawn facing down (+Y). So we add PI to flip it to face the road.
	var final_angle = angle + PI
	
	# Flip the texture horizontally on the North and West sides to keep the porch visually on the same side
	if angle > 0.1:
		sprite.flip_h = true
		
	sprite.rotation = final_angle
	sprite.position = pos
	sprite.texture = tex
	add_child(sprite)

	_houses.append(sprite)


func _cell_is_enclosed(r: int, c: int) -> bool:
	return _h_segs[r][c] and _h_segs[r + 1][c] \
		and _v_segs[r][c] and _v_segs[r][c + 1]


# ── Car spawn ─────────────────────────────────────────────────────────────────

func _spawn_cars() -> void:
	for p in range(GameSettings.player_count):
		var car := _spawn_car_for_player(p + 1)
		if car != null:
			_cars.append(car)
	# Set legacy reference for minimap (P1)
	if _cars.size() > 0:
		_car = _cars[0]


func _spawn_car_for_player(player_id: int) -> Node2D:
	if car_scene == null:
		return null
	var car := car_scene.instantiate() as Node2D
	car.name = "Car_P%d" % player_id

	# Set the player_id so the car reads the right input actions
	car.player_id = player_id
	car.real_player_index = player_id - 1

	# In online mode, only the local player's car accepts input
	if GameSettings.is_online:
		var p_idx := player_id - 1  # player_id is 1-based
		car.is_local = (p_idx == _local_player_idx)
		# All online players use WASD (p1 actions)
		if car.is_local:
			car.player_id = 1  # force P1 actions for WASD

	# Spawn equally close to the post office, parked on the road in front of it
	if _post_office != null:
		var po_pos := _post_office.global_position
		# The house's local +Y axis points toward the road (since we rotated the house by PI)
		var house_fwd := Vector2.DOWN.rotated(_post_office.rotation)
		var road_center := po_pos + house_fwd * 1258.0
		
		# Offset cars sideways along the road
		var right_dir := house_fwd.rotated(PI / 2.0)
		var p_idx := player_id - 1
		var offset_val = (float(p_idx) - (GameSettings.player_count - 1) / 2.0) * 500.0
		car.position = road_center + right_dir * offset_val
		
		# Face the cars along the road
		car.rotation = _post_office.rotation + PI / 2.0
	else:
		car.position = Vector2.ZERO
		car.rotation = 0.0

	# Create VisualRoot for smooth swiveling
	var vis_root = Node2D.new()
	vis_root.name = "VisualRoot"
	car.add_child(vis_root)

	# Player-specific color tinting (multiplied to make it glow with HDR)
	var sprite = car.get_node_or_null("Sprite2D")
	if sprite != null:
		var c = _player_colors[(player_id - 1) % 4]
		sprite.modulate = Color(c.r * 1.5, c.g * 1.5, c.b * 1.5)
		car.remove_child(sprite)
		vis_root.add_child(sprite)

	# Add headlights to the car
	_attach_headlights(car)

	# Remove the Camera2D from the car scene — we use our own SubViewport cameras
	var car_cam = car.get_node_or_null("Camera2D")
	if car_cam != null:
		car_cam.queue_free()

	add_child(car)
	return car


func _spawn_npcs() -> void:
	if npc_car_scene == null or _traffic_paths.is_empty():
		return

	var per_path: Dictionary = {}
	for i in range(25):
		var npc = npc_car_scene.instantiate() as Node2D
		add_child(npc)
		var path_idx := i % _traffic_paths.size()
		var path: Array = _traffic_paths[path_idx]
		var slot: int = per_path.get(path_idx, 0)
		per_path[path_idx] = slot + 1

		var slots_on_path := ceili(25.0 / float(_traffic_paths.size()))
		var step := maxi(path.size() / slots_on_path, 1)
		var start_idx := (slot * step) % path.size()
		npc.init_route(path, start_idx, self)

		var next_idx := (start_idx + 1) % path.size()
		var seg: Vector2 = (path[next_idx] - path[start_idx]).normalized()
		if seg.length_squared() > 0.01:
			npc.position += seg * _rng.randf_range(300.0, 1200.0)
			
		var sprite = npc.get_node_or_null("Sprite2D")
		if sprite != null:
			var c = _player_colors[1] # Player 2 color
			sprite.modulate = Color(c.r * 1.5, c.g * 1.5, c.b * 1.5)
			
		_npcs.append(npc)


func _spawn_one_npc() -> void:
	if npc_car_scene == null or _traffic_paths.is_empty():
		return
	var npc = npc_car_scene.instantiate() as Node2D
	add_child(npc)
	var path_idx := _rng.randi_range(0, _traffic_paths.size() - 1)
	var path: Array = _traffic_paths[path_idx]
	var start_idx := _rng.randi_range(0, path.size() - 1)
	npc.init_route(path, start_idx, self)
	
	var next_idx := (start_idx + 1) % path.size()
	var dir: Vector2 = (path[next_idx] - path[start_idx]).normalized()
	if dir.length_squared() > 0.01:
		npc.rotation = dir.angle() + PI * 0.5
		
	var sprite = npc.get_node_or_null("Sprite2D")
	if sprite != null:
		var c = _player_colors[1] # Player 2 color
		sprite.modulate = Color(c.r * 1.5, c.g * 1.5, c.b * 1.5)
		
	_npcs.append(npc)


func _spawn_one_cop() -> void:
	var cop_scene = load("res://scenes/cop_car.tscn")
	if cop_scene == null or _traffic_paths.is_empty():
		return
	var cop = cop_scene.instantiate() as Node2D
	add_child(cop)
	var path_idx := _rng.randi_range(0, _traffic_paths.size() - 1)
	var path: Array = _traffic_paths[path_idx]
	var start_idx := _rng.randi_range(0, path.size() - 1)
	cop.init_route(path, start_idx, self)
	
	var next_idx := (start_idx + 1) % path.size()
	var dir: Vector2 = (path[next_idx] - path[start_idx]).normalized()
	if dir.length_squared() > 0.01:
		cop.rotation = dir.angle() + PI * 0.5
		
	var sprite = cop.get_node_or_null("Sprite2D")
	if sprite != null:
		# Make cop cars glow red/blue intensely
		sprite.modulate = Color(1.5, 1.2, 1.5)
		
	_attach_headlights(cop)
	_cops.append(cop)


func _attach_headlights(car_node: Node2D) -> void:
	var target = car_node.get_node_or_null("VisualRoot")
	if target == null:
		target = car_node
		
	for y_offset in [-35, 35]:
		var light = PointLight2D.new()
		var tex = preload("res://assets/headlight.png")
		light.texture = tex
		light.offset = Vector2(256, 0)
		light.energy = 1.0
		light.scale = Vector2(2.5, 2.5)
		light.position = Vector2(240, y_offset) # Moved to the very front bumper
		target.add_child(light)


# ── Grass background ──────────────────────────────────────────────────────────

func _spawn_grass_bg() -> void:
	var pad     := _cell_size            # one extra cell of padding on every edge
	var total_w := grid_cols * _cell_size + pad * 2.0
	var total_h := grid_rows * _cell_size + pad * 2.0

	var bg = ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.05) # Pure dark Cyberpunk background
	bg.position = Vector2(-total_w * 0.5, -total_h * 0.5)
	bg.size = Vector2(total_w, total_h)
	bg.z_index = -100
	add_child(bg)
	move_child(bg, 0)


# ── Minimap ───────────────────────────────────────────────────────────────────

func _build_minimap() -> void:
	# Build a per-player minimap overlay inside each SubViewport
	for p in range(GameSettings.player_count):
		if p >= _viewports.size() or _viewports[p] == null:
			_minimaps.append(null)
			continue

		# CanvasLayer so the minimap stays screen-fixed
		var mm_layer := CanvasLayer.new()
		mm_layer.layer = 10
		_viewports[p].add_child(mm_layer)

		# Container that holds the dark overlay + map drawing
		var mm_root := Control.new()
		mm_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mm_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mm_root.visible = false
		mm_layer.add_child(mm_root)
		_minimaps.append(mm_root)

		# Dark semi-transparent overlay (only covers this player's viewport)
		var bg := ColorRect.new()
		bg.color = Color(0, 0, 0, 0.55)
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mm_root.add_child(bg)

		# The actual minimap drawing node
		var mm := _MinimapDraw.new()
		mm.main       = self
		mm.player_idx = p
		mm.size       = Vector2(260, 260)
		mm.anchor_left   = 0.5
		mm.anchor_right  = 0.5
		mm.anchor_top    = 0.5
		mm.anchor_bottom = 0.5
		mm.offset_left   = -130.0
		mm.offset_right  = 130.0
		mm.offset_top    = -130.0
		mm.offset_bottom = 130.0
		mm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mm_root.add_child(mm)


# ── Minimap draw node (inner class) ──────────────────────────────────────────

class _MinimapDraw extends Control:
	var main : Node2D   # reference to the Main node
	var player_idx : int = 0  # which player this minimap belongs to

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var m := main

		# How many world units the minimap covers total.
		var world_span := Vector2(
			(m.grid_cols + 1) * m._cell_size,
			(m.grid_rows + 1) * m._cell_size
		)
		var pad   := 12.0
		var draw_size := size - Vector2(pad, pad) * 2.0
		var scale_v   := draw_size / world_span
		var origin    := Vector2(pad, pad)  # top-left of drawing area

		# world origin is centred, so shift by half the total world span first.
		var half_world := world_span / 2.0

		# ── Background panel ─────────────────────────────────────────────────
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.12, 0.92), true)
		var border_color : Color = m._player_colors[player_idx % 4]
		draw_rect(Rect2(Vector2.ZERO, size), border_color.lerp(Color.WHITE, 0.3) * Color(1,1,1,0.6), false, 2.0)

		# ── Roads ────────────────────────────────────────────────────────────
		var road_color   := Color(0.55, 0.55, 0.6, 1.0)
		var road_px_w    := maxf(2.0, m._road_width * scale_v.x)

		# Horizontal segments
		for r in range(m.grid_rows + 1):
			for c in range(m.grid_cols):
				if not m._h_segs[r][c]:
					continue
				var wx0 : float = m._world_pos(c,       r).x + half_world.x
				var wx1 : float = m._world_pos(c + 1.0, r).x + half_world.x
				var wy  : float = m._world_pos(c,       r).y + half_world.y
				var p0  := origin + Vector2(wx0 * scale_v.x, wy * scale_v.y)
				var p1  := origin + Vector2(wx1 * scale_v.x, wy * scale_v.y)
				draw_line(p0, p1, road_color, road_px_w)

		# Vertical segments
		for r in range(m.grid_rows):
			for c in range(m.grid_cols + 1):
				if not m._v_segs[r][c]:
					continue
				var wx  : float = m._world_pos(c, r      ).x + half_world.x
				var wy0 : float = m._world_pos(c, r      ).y + half_world.y
				var wy1 : float = m._world_pos(c, r + 1.0).y + half_world.y
				var p0  := origin + Vector2(wx * scale_v.x, wy0 * scale_v.y)
				var p1  := origin + Vector2(wx * scale_v.x, wy1 * scale_v.y)
				draw_line(p0, p1, road_color, road_px_w)

		# ── Houses (grey dots) ────────────────────────────────────────────────
		for h in m._houses:
			var cw : Vector2 = h.position + half_world
			var cp := origin + Vector2(cw.x * scale_v.x, cw.y * scale_v.y)
			draw_rect(Rect2(cp - Vector2(2, 2), Vector2(4, 4)), Color(0.6, 0.6, 0.6, 0.5))

		# ── Only this player's target houses ─────────────────────────────────
		var my_color : Color = m._player_colors[player_idx % 4]
		var my_targets : Array = m._player_targets[player_idx]
		for h in my_targets:
			var cw : Vector2 = h.position + half_world
			var cp := origin + Vector2(cw.x * scale_v.x, cw.y * scale_v.y)
			draw_rect(Rect2(cp - Vector2(4, 4), Vector2(8, 8)), my_color)

		# ── Post office ──────────────────────────────────────────────────────
		if m._post_office != null:
			var cw : Vector2 = m._post_office.position + half_world
			var cp := origin + Vector2(cw.x * scale_v.x, cw.y * scale_v.y)
			draw_rect(Rect2(cp - Vector2(5, 5), Vector2(10, 10)), Color(0.2, 0.4, 1.0, 1.0))
			draw_rect(Rect2(cp - Vector2(5, 5), Vector2(10, 10)), Color(1, 1, 1, 1), false, 1.0)

		# ── Car dots (all players) ──────────────────────────────────────────
		for p in range(m._cars.size()):
			var car : Node2D = m._cars[p]
			if car == null:
				continue
			var c_color : Color = m._player_colors[p % 4]
			var cw  : Vector2 = car.position + half_world
			var cp  := origin + Vector2(cw.x * scale_v.x, cw.y * scale_v.y)
			var dot_size := 7.0 if p == player_idx else 4.0
			draw_circle(cp, dot_size, c_color)
			if p == player_idx:
				draw_circle(cp, dot_size, Color(1.0, 1.0, 1.0, 0.7), false, 1.5)

		# ── Label ────────────────────────────────────────────────────────────
		var label_text := "P%d MAP" % (player_idx + 1)
		draw_string(ThemeDB.fallback_font, Vector2(8, size.y - 8),
			label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(0.7, 0.7, 0.9, 0.8))
