extends Node2D

const RoadPathGeneratorScript := preload("res://road_path_generator.gd")

# ── Scenes & textures ──────────────────────────────────────────────────────────
@export var straight_road_scene : PackedScene
@export var four_way_scene      : PackedScene  # all 4 roads meet
@export var three_way_scene     : PackedScene  # T-junction (base = missing north)
@export var l_corner_scene      : PackedScene  # 90° corner  (base = south + west)
@export var straight_inter_scene: PackedScene  # straight-through (base = north + south)
@export var car_scene           : PackedScene

const HOUSE_TEXTURE_PATH := "res://assets/house.png"
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
const HOUSE_SCALE    := 12.0  # visual scale for house sprite
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

# Per-player state (index 0 = P1, index 1 = P2)
var _cars : Array[Node2D] = []
var _cameras : Array[Camera2D] = []
var _player_packages : Array[int] = [0, 0]
var _player_scores   : Array[int] = [0, 0]
var _player_targets  : Array = [[], []]  # Array of Array[Sprite2D]
var _ui_packages : Array[Label] = []
var _ui_scores   : Array[Label] = []

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

var npc_car_scene = preload("res://npc_car.tscn")
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
var _global_results_screen : Control

# ── Per-player minimaps ───────────────────────────────────────────────────────
var _minimaps : Array[Control] = []  # one per player, inside their SubViewport

# Player colors for identification
const P1_COLOR := Color(0.3, 0.6, 1.0)   # blue
const P2_COLOR := Color(1.0, 0.35, 0.3)  # red


func _ready() -> void:
	if map_seed == 0:
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
	_spawn_both_cars()
	_spawn_npcs()
	_build_minimap()
	_update_ui(0)
	_update_ui(1)
	_box_tex = load(BOX_TEXTURE_PATH)

	_round_timer = GameSettings.round_time
	# Freeze cars during countdown
	for car in _cars:
		if car != null:
			car.frozen = true


# ── Split-screen setup ───────────────────────────────────────────────────────

func _setup_split_screen() -> void:
	# We'll create an HBoxContainer with two SubViewportContainers
	# Each SubViewport shares the same World2D (this scene's world)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 4)

	# We need a CanvasLayer to put the split-screen containers on top
	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 0
	add_child(ui_layer)
	ui_layer.add_child(hbox)

	for p in range(2):
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		hbox.add_child(container)

		var viewport := SubViewport.new()
		viewport.handle_input_locally = false
		viewport.canvas_cull_mask = 0xFFFFFFFF
		viewport.world_2d = get_viewport().world_2d  # share the same world
		viewport.transparent_bg = false
		# Keep pixel-art crisp (nearest-neighbor filtering)
		viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		container.add_child(viewport)

		# Camera for this player
		var cam := Camera2D.new()
		cam.zoom = Vector2(0.25, 0.25)
		cam.name = "P%dCamera" % (p + 1)
		viewport.add_child(cam)
		_cameras.append(cam)

		_viewports.append(viewport)
		_viewport_containers.append(container)

	# Separator line between viewports
	var sep := ColorRect.new()
	sep.color = Color(0.2, 0.2, 0.3, 1.0)
	sep.custom_minimum_size = Vector2(4, 0)
	sep.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Insert between the two containers
	hbox.move_child(sep, 1)

	# Build per-player HUD overlays
	for p in range(2):
		_build_player_hud(p)

	# ── Global results screen overlay ─────────────────────────────────────────
	_global_results_screen = ColorRect.new()
	_global_results_screen.color = Color(0, 0, 0, 0.8)
	_global_results_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_global_results_screen.visible = false
	ui_layer.add_child(_global_results_screen)


func _build_player_hud(player_idx: int) -> void:
	var font = load("res://assets/Poppins-Medium.ttf") as Font

	# Each player gets a CanvasLayer inside their SubViewport so the HUD
	# stays screen-fixed and doesn't move with the Camera2D.
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 5
	_viewports[player_idx].add_child(hud_layer)

	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(hud)

	var player_color : Color = P1_COLOR if player_idx == 0 else P2_COLOR
	var minimap_key := "TAB" if player_idx == 0 else "R-CTRL"

	# ── Top bar background ──────────────────────────────────────────────────
	var top_bar := ColorRect.new()
	top_bar.color = Color(0.0, 0.0, 0.0, 0.45)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = 52
	hud.add_child(top_bar)

	# HBox for the top bar content
	var top_hbox := HBoxContainer.new()
	top_hbox.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_hbox.offset_left = 12
	top_hbox.offset_right = -12
	top_hbox.offset_top = 6
	top_hbox.offset_bottom = 48
	top_hbox.add_theme_constant_override("separation", 20)
	hud.add_child(top_hbox)

	# Player tag
	var p_label := Label.new()
	p_label.text = "P%d" % (player_idx + 1)
	if font != null:
		p_label.add_theme_font_override("font", font)
	p_label.add_theme_font_size_override("font_size", 28)
	p_label.add_theme_color_override("font_color", player_color)
	p_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	p_label.add_theme_constant_override("outline_size", 4)
	top_hbox.add_child(p_label)

	# Package icon + count
	var pkg_label := Label.new()
	pkg_label.text = ""
	if font != null:
		pkg_label.add_theme_font_override("font", font)
	pkg_label.add_theme_font_size_override("font_size", 26)
	pkg_label.add_theme_color_override("font_color", Color(1, 1, 1))
	pkg_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	pkg_label.add_theme_constant_override("outline_size", 4)
	top_hbox.add_child(pkg_label)
	_ui_packages.append(pkg_label)

	# Score icon + count
	var score_label := Label.new()
	score_label.text = ""
	if font != null:
		score_label.add_theme_font_override("font", font)
	score_label.add_theme_font_size_override("font_size", 26)
	score_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	score_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	score_label.add_theme_constant_override("outline_size", 4)
	top_hbox.add_child(score_label)
	_ui_scores.append(score_label)

	# Spacer
	var spacer1 := Control.new()
	spacer1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_hbox.add_child(spacer1)

	# Round timer
	var time_label := Label.new()
	time_label.text = "0:00"
	if font != null:
		time_label.add_theme_font_override("font", font)
	time_label.add_theme_font_size_override("font_size", 28)
	time_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	time_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	time_label.add_theme_constant_override("outline_size", 4)
	top_hbox.add_child(time_label)
	_ui_round_timers.append(time_label)

	# Spacer to push minimap hint to the right
	var spacer2 := Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_hbox.add_child(spacer2)

	# Minimap key hint
	var mm_hint := Label.new()
	mm_hint.text = minimap_key + " = Map"
	if font != null:
		mm_hint.add_theme_font_override("font", font)
	mm_hint.add_theme_font_size_override("font_size", 18)
	mm_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	top_hbox.add_child(mm_hint)

	# ── Center screen messages (countdown) ──────────────────────────────────
	var center_lbl := Label.new()
	center_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	if font != null:
		center_lbl.add_theme_font_override("font", font)
	center_lbl.add_theme_font_size_override("font_size", 120)
	center_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
	center_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	center_lbl.add_theme_constant_override("outline_size", 8)
	hud.add_child(center_lbl)
	_ui_center_labels.append(center_lbl)

	# ── Target Indicators ────────────────────────────────────────────────────
	var indicator_script := load("res://target_indicators.gd") as Script
	if indicator_script != null:
		var indicator := Control.new()
		indicator.set_script(indicator_script)
		indicator.player_idx = player_idx
		indicator.main_ref = self
		indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hud.add_child(indicator)
		hud.move_child(indicator, 0)


func _process(delta: float) -> void:
	_process_game_state(delta)

	# Update cameras to follow cars
	for p in range(2):
		if p < _cars.size() and _cars[p] != null and p < _cameras.size():
			_cameras[p].global_position = _cars[p].global_position

	if _game_state != "playing":
		return

	# Respawn NPCs if any despawned
	_npcs = _npcs.filter(func(n): return is_instance_valid(n) and not n.is_queued_for_deletion())
	if _npcs.size() < 25:
		_spawn_one_npc()

	# Per-player game logic
	for p in range(2):
		if p >= _cars.size() or _cars[p] == null:
			continue

		var car_pos := _cars[p].global_position
		var speed : float = 0.0
		if "velocity" in _cars[p]:
			speed = _cars[p].velocity.length()

		# Check Post Office (pickup — no box thrown)
		if _post_office != null and _player_packages[p] == 0 and speed < 400.0:
			if car_pos.distance_to(_post_office.global_position) < 2000.0:
				_player_packages[p] = 5
				_assign_random_deliveries(p)
				_update_ui(p)

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


func _process_game_state(delta: float) -> void:
	if _game_state == "countdown":
		var old_sec := int(ceil(_countdown_timer))
		_countdown_timer -= delta
		var new_sec := int(ceil(_countdown_timer))

		if _countdown_timer <= 0.0:
			_game_state = "playing"
			for lbl in _ui_center_labels:
				lbl.text = "GO!"
				lbl.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
			for car in _cars:
				if car != null:
					car.frozen = false

			# Fade out "GO!" after 1 second
			var tw := create_tween()
			for lbl in _ui_center_labels:
				tw.tween_property(lbl, "modulate:a", 0.0, 1.0)
		else:
			for lbl in _ui_center_labels:
				lbl.text = str(new_sec)

	elif _game_state == "playing":
		_round_timer -= delta
		if _round_timer <= 0.0:
			_round_timer = 0.0
			_end_game()

		# Update UI timers
		var m := int(_round_timer) / 60
		var s := int(_round_timer) % 60
		var time_str := "%d:%02d" % [m, s]
		for lbl in _ui_round_timers:
			lbl.text = time_str
			if _round_timer <= 10.0:
				lbl.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))


func _end_game() -> void:
	_game_state = "finished"
	for car in _cars:
		if car != null:
			car.frozen = true

	# Determine winner
	var s1 = _player_scores[0]
	var s2 = _player_scores[1]
	var diff = abs(s1 - s2)
	var win_text := ""
	var win_color := Color.WHITE

	if s1 > s2:
		win_text = "PLAYER 1 WINS!\nby %d points" % diff
		win_color = P1_COLOR
	elif s2 > s1:
		win_text = "PLAYER 2 WINS!\nby %d points" % diff
		win_color = P2_COLOR
	else:
		win_text = "IT'S A TIE!"
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
	btn.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://main_menu.tscn"))
	vbox.add_child(btn)

	# Make sure mouse is visible again since we need to click
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE




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


func _input(event: InputEvent) -> void:
	# P1 minimap toggle: Tab
	if event is InputEventKey and event.pressed and not event.echo:
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
		
		var po_tex = load("res://assets/post_office.png")
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
	sprite.texture = tex
	sprite.scale   = Vector2(HOUSE_SCALE, HOUSE_SCALE)
	sprite.rotation = angle
	sprite.position = pos
	add_child(sprite)

	_houses.append(sprite)


func _cell_is_enclosed(r: int, c: int) -> bool:
	return _h_segs[r][c] and _h_segs[r + 1][c] \
		and _v_segs[r][c] and _v_segs[r][c + 1]


# ── Car spawn ─────────────────────────────────────────────────────────────────

func _spawn_both_cars() -> void:
	for p in range(2):
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

	# Spawn equally close to the post office, parked on the road in front of it
	if _post_office != null:
		var po_pos := _post_office.global_position
		# The house's local -Y axis points toward the road (distance is ~1258 units)
		var house_fwd := Vector2.UP.rotated(_post_office.rotation)
		var road_center := po_pos + house_fwd * 1258.0
		
		# Offset cars sideways along the road
		var right_dir := house_fwd.rotated(PI / 2.0)
		if player_id == 1:
			car.position = road_center - right_dir * 500.0
		else:
			car.position = road_center + right_dir * 500.0
		
		# Face the cars along the road
		car.rotation = _post_office.rotation + PI / 2.0
	else:
		car.position = Vector2.ZERO
		car.rotation = 0.0

	# Player-specific color tinting
	var sprite = car.get_node_or_null("Sprite2D")
	if sprite != null:
		if player_id == 1:
			sprite.modulate = P1_COLOR
		else:
			sprite.modulate = P2_COLOR

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
	_npcs.append(npc)


# ── Grass background ──────────────────────────────────────────────────────────

func _spawn_grass_bg() -> void:
	var tex : Texture2D = load("res://assets/grass_4x4.png")
	if tex == null:
		push_error("Could not load grass texture")
		return

	# Match the pixel-art scale used by every other asset.
	const TILE_SCALE := 63.1875
	var pad     := _cell_size            # one extra cell of padding on every edge
	var total_w := grid_cols * _cell_size + pad * 2.0
	var total_h := grid_rows * _cell_size + pad * 2.0

	var bg := _GrassBg.new()
	bg.tex   = tex
	bg.scale = Vector2(TILE_SCALE, TILE_SCALE)
	# Rect is in LOCAL (pre-scale) space so we divide by the scale.
	bg.rect  = Rect2(
		Vector2(-total_w * 0.5 / TILE_SCALE, -total_h * 0.5 / TILE_SCALE),
		Vector2(total_w / TILE_SCALE,          total_h / TILE_SCALE)
	)
	add_child(bg)
	move_child(bg, 0)   # push behind roads, houses, etc.


class _GrassBg extends Node2D:
	var tex  : Texture2D
	var rect : Rect2

	func _draw() -> void:
		if tex != null:
			draw_texture_rect(tex, rect, true)  # true = tile


# ── Minimap ───────────────────────────────────────────────────────────────────

func _build_minimap() -> void:
	# Build a per-player minimap overlay inside each SubViewport
	for p in range(2):
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
		var border_color : Color = m.P1_COLOR if player_idx == 0 else m.P2_COLOR
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
		var my_color : Color = m.P1_COLOR if player_idx == 0 else m.P2_COLOR
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

		# ── Car dots (both players) ──────────────────────────────────────────
		for p in range(m._cars.size()):
			var car : Node2D = m._cars[p]
			if car == null:
				continue
			var c_color : Color = m.P1_COLOR if p == 0 else m.P2_COLOR
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
