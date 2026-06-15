extends CharacterBody2D

var speed := 400.0
var target_pos := Vector2.ZERO
var graph_ref : Node2D = null
var current_c := 0
var current_r := 0
var target_c := 0
var target_r := 0
var is_destroyed := false

@onready var ray_front = $RayFront
@onready var ray_left = $RayLeft
@onready var ray_right = $RayRight
@onready var sprite = $Sprite2D

func _ready():
	sprite.modulate = Color(randf_range(0.2, 1.0), randf_range(0.2, 1.0), randf_range(0.2, 1.0))

func init_path(c: int, r: int, tc: int, tr: int, m: Node2D):
	graph_ref = m
	current_c = c
	current_r = r
	target_c = tc
	target_r = tr
	
	position = _get_lane_pos(current_c, current_r, target_c, target_r)
	target_pos = _get_lane_pos(current_c, current_r, target_c, target_r)
	
	var dir = (target_pos - position).normalized()
	if dir.length_squared() > 0.1:
		rotation = dir.angle()

func _get_lane_pos(c1: int, r1: int, c2: int, r2: int) -> Vector2:
	var raw = graph_ref._world_pos(float(c2), float(r2))
	var dir = Vector2(c2 - c1, r2 - r1).normalized()
	var offset = Vector2(dir.y, -dir.x) * 350.0
	return raw + offset

func _pick_next_node():
	var possible := []
	var r = target_r
	var c = target_c
	var g = graph_ref
	
	if r > 0 and g._v_segs[r-1][c] and not (current_r == r-1 and current_c == c):
		possible.append(Vector2(c, r-1))
	if r < g.grid_rows and g._v_segs[r][c] and not (current_r == r+1 and current_c == c):
		possible.append(Vector2(c, r+1))
	if c > 0 and g._h_segs[r][c-1] and not (current_r == r and current_c == c-1):
		possible.append(Vector2(c-1, r))
	if c < g.grid_cols and g._h_segs[r][c] and not (current_r == r and current_c == c+1):
		possible.append(Vector2(c+1, r))
		
	if possible.size() == 0:
		possible.append(Vector2(current_c, current_r))
		
	var next = possible.pick_random()
	current_c = target_c
	current_r = target_r
	target_c = int(next.x)
	target_r = int(next.y)
	target_pos = _get_lane_pos(current_c, current_r, target_c, target_r)

func _physics_process(delta: float) -> void:
	if is_destroyed or graph_ref == null:
		return
		
	var dist = position.distance_to(target_pos)
	if dist < 400.0:
		_pick_next_node()
		return

	var should_brake = false
	if ray_front.is_colliding() and ray_front.get_collider() != self:
		should_brake = true
	if ray_left.is_colliding() and ray_left.get_collider() != self:
		should_brake = true
	if ray_right.is_colliding() and ray_right.get_collider() != self:
		should_brake = true

	if should_brake:
		velocity = velocity.move_toward(Vector2.ZERO, 1500 * delta)
	else:
		var dir = (target_pos - position).normalized()
		rotation = lerp_angle(rotation, dir.angle(), 4.0 * delta)
		var forward = Vector2(cos(rotation), sin(rotation))
		velocity = velocity.move_toward(forward * speed, 300 * delta)
		
	move_and_slide()
	
	for i in get_slide_collision_count():
		var collision = get_slide_collision(i)
		var col = collision.get_collider()
		if col != null and col.name == "Car":
			_destroy()
			break

func _destroy():
	is_destroyed = true
	var tex = load("res://assets/npc_car_destroyed.png")
	if tex:
		sprite.texture = tex
	velocity = Vector2.ZERO
