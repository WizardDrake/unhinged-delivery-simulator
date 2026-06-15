extends Node2D

# ── Scenes & textures ──────────────────────────────────────────────────────────
@export var straight_road_scene : PackedScene
@export var four_way_scene      : PackedScene  # all 4 roads meet
@export var three_way_scene     : PackedScene  # T-junction (base = missing north)
@export var l_corner_scene      : PackedScene  # 90° corner  (base = south + west)
@export var straight_inter_scene: PackedScene  # straight-through (base = north + south)
@export var car_scene           : PackedScene

const HOUSE_TEXTURE_PATH := "res://assets/house.png"

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
const HOUSE_SCALE    := 5.0   # visual scale for house sprite
const CURB_OFFSET    := 60.0  # extra gap from road edge → house centre

# Filled in by _measure_scenes().
var _cell_size   : float = 5560.0
var _road_length : float = 4044.0
var _road_width  : float = 1516.0
var _inter_size  : float = 1516.0

# ── Internal state ─────────────────────────────────────────────────────────────
var _rng  := RandomNumberGenerator.new()
var _car  : Node2D   # reference used by minimap

# h_segs[row][col] = true  →  horizontal road running right from node (col, row)
# v_segs[row][col] = true  →  vertical road running down from node (col, row)
var _h_segs : Array
var _v_segs : Array

# ── Minimap ────────────────────────────────────────────────────────────────────
var _minimap : CanvasLayer


func _ready() -> void:
	if map_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = map_seed

	_measure_scenes()
	_spawn_grass_bg()       # must be first child so it draws behind everything
	_init_segment_arrays()
	_place_roads()
	_place_houses()
	_car = _spawn_car()
	_build_minimap()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_focus_next"):   # Tab key
		_minimap.visible = not _minimap.visible


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
	var end_margin := _inter_size * 0.3

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
			_place_curb_houses_v(tex, road_x + from_road, y0, y1,  PI * 0.5)  # east side
			_place_curb_houses_v(tex, road_x - from_road, y0, y1, -PI * 0.5)  # west side


## Place `houses_per_side` houses evenly spaced along a horizontal curb strip.
## `facing_angle` is the sprite rotation so the house faces the road.
func _place_curb_houses(tex: Texture2D, x0: float, x1: float, y: float, facing_angle: float) -> void:
	if x1 <= x0:
		return
	for i in range(houses_per_side):
		var t := (i + 0.5) / float(houses_per_side)
		var jitter := _rng.randf_range(-0.08, 0.08)
		var x : float = lerp(x0, x1, clampf(t + jitter, 0.0, 1.0))
		_spawn_house(tex, Vector2(x, y), facing_angle)


## Same but along a vertical curb strip.
func _place_curb_houses_v(tex: Texture2D, x: float, y0: float, y1: float, facing_angle: float) -> void:
	if y1 <= y0:
		return
	for i in range(houses_per_side):
		var t := (i + 0.5) / float(houses_per_side)
		var jitter := _rng.randf_range(-0.08, 0.08)
		var y : float = lerp(y0, y1, clampf(t + jitter, 0.0, 1.0))
		_spawn_house(tex, Vector2(x, y), facing_angle)


func _spawn_house(tex: Texture2D, pos: Vector2, angle: float) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.scale   = Vector2(HOUSE_SCALE, HOUSE_SCALE)
	sprite.rotation = angle
	sprite.position = pos
	add_child(sprite)


func _cell_is_enclosed(r: int, c: int) -> bool:
	return _h_segs[r][c] and _h_segs[r + 1][c] \
		and _v_segs[r][c] and _v_segs[r][c + 1]


# ── Car spawn ─────────────────────────────────────────────────────────────────

func _spawn_car() -> Node2D:
	if car_scene == null:
		return null
	var car := car_scene.instantiate() as Node2D
	car.position = _world_pos(0, 0)
	car.rotation  = 0.0
	add_child(car)
	return car


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
	_minimap = CanvasLayer.new()
	_minimap.layer = 10
	_minimap.visible = false
	add_child(_minimap)

	# Dark semi-transparent panel behind everything.
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_minimap.add_child(bg)

	# The actual minimap drawing node.
	var mm := _MinimapDraw.new()
	mm.main        = self
	mm.size        = Vector2(280, 280)
	mm.anchor_left   = 1.0
	mm.anchor_right  = 1.0
	mm.anchor_top    = 0.0
	mm.anchor_bottom = 0.0
	mm.offset_left   = -300.0
	mm.offset_right  = -20.0
	mm.offset_top    = 20.0
	mm.offset_bottom = 300.0
	_minimap.add_child(mm)

	# "TAB – minimap" hint always visible (not inside the overlay).
	var hint_layer := CanvasLayer.new()
	hint_layer.layer = 9
	add_child(hint_layer)

	var hint := Label.new()
	hint.text = "TAB  –  minimap"
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	hint.anchor_left   = 0.0
	hint.anchor_right  = 0.0
	hint.anchor_top    = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left   = 16.0
	hint.offset_top    = -32.0
	hint.offset_bottom = 0.0
	hint_layer.add_child(hint)


# ── Minimap draw node (inner class) ──────────────────────────────────────────

class _MinimapDraw extends Control:
	var main : Node2D  # reference to the Main node

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

		# Helper: world → minimap local pixel
		# world origin is centred, so shift by half the total world span first.
		var half_world := world_span / 2.0

		# ── Background panel ─────────────────────────────────────────────────
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.12, 0.92), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.6, 1.0, 0.5), false, 2.0)

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

		# ── Car dot ──────────────────────────────────────────────────────────
		if m._car != null:
			var cw  : Vector2 = m._car.position + half_world
			var cp  := origin + Vector2(cw.x * scale_v.x, cw.y * scale_v.y)
			draw_circle(cp, 6.0, Color(1.0, 0.3, 0.2))
			draw_circle(cp, 6.0, Color(1.0, 1.0, 1.0, 0.7), false, 1.5)

		# ── Label ────────────────────────────────────────────────────────────
		draw_string(ThemeDB.fallback_font, Vector2(8, size.y - 8),
			"MINIMAP", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(0.7, 0.7, 0.9, 0.8))
