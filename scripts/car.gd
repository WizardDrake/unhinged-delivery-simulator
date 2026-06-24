extends CharacterBody2D

var wheel_base = 200
var steering_angle = 20
var engine_power = 1500
var friction = -1
var drag = -0.009
var braking = -1350
var max_speed_reverse = 600
var slip_speed = 400
var traction_fast = 2.5
var traction_slow = 5

var acceleration = Vector2.ZERO
var steer_direction = 0.0

## Which player controls this car: 1 or 2.
## Set by main.gd before the first physics frame.
var player_id : int = 1

## When true, the car ignores all input and doesn't move.
var frozen : bool = true

## When false, this car is controlled by a remote player (no local input).
var is_local : bool = true

## Synced state from remote player (used when is_local == false)
var _sync_pos      := Vector2.ZERO
var _sync_rot      := 0.0
var _sync_vel      := Vector2.ZERO
var _sync_steer    := 0.0
var _has_sync_data := false

var _drift_l : CPUParticles2D
var _drift_r : CPUParticles2D

var spinout_timer : float = 0.0

# Input action names resolved from player_id
var _action_left  : String
var _action_right : String
var _action_accel : String
var _action_brake : String

func _ready() -> void:
	_action_left  = "p%d_steer_left"  % player_id
	_action_right = "p%d_steer_right" % player_id
	_action_accel = "p%d_accelerate"  % player_id
	_action_brake = "p%d_brake"       % player_id

	# Apply settings from the global singleton
	engine_power   = GameSettings.engine_power
	braking        = -GameSettings.braking_power
	steering_angle = GameSettings.steering_angle

	_drift_l = _create_drift_particles()
	_drift_l.position = Vector2(-160, -45)
	add_child(_drift_l)
	
	_drift_r = _create_drift_particles()
	_drift_r.position = Vector2(-160, 45)
	add_child(_drift_r)


func trigger_spinout() -> void:
	if spinout_timer <= 0.0:
		spinout_timer = 1.5

func _physics_process(delta):
	if frozen:
		velocity = Vector2.ZERO
		return

	if not is_local:
		# Remote car — interpolate toward synced state
		if _has_sync_data:
			position = position.lerp(_sync_pos, 12.0 * delta)
			rotation = lerp_angle(rotation, _sync_rot, 12.0 * delta)
			velocity = _sync_vel
			steer_direction = _sync_steer
		# Update drift particles for remote car too
		var slip_cos2 := transform.x.dot(velocity.normalized()) if velocity.length_squared() > 1.0 else 1.0
		var slip_angle2 := rad_to_deg(acos(clampf(slip_cos2, -1.0, 1.0)))
		var fwd2 := velocity.dot(transform.x) > 100.0
		var drift2 := fwd2 and (absf(rad_to_deg(steer_direction)) >= 75.0 or slip_angle2 >= 25.0) and velocity.length() > 450.0
		_drift_l.emitting = drift2
		_drift_r.emitting = drift2
		return

	if spinout_timer > 0.0:
		spinout_timer -= delta
		rotation += 15.0 * delta
		velocity *= 0.98
		move_and_slide()
		_push_npc_hits()
		
		# Emit particles while spinning out
		_drift_l.emitting = true
		_drift_r.emitting = true
		return

	acceleration = Vector2.ZERO
	get_input()
		
	apply_friction(delta)
	calculate_steering(delta)
	velocity += acceleration * delta
	move_and_slide()
	_push_npc_hits()

	var slip_cos := transform.x.dot(velocity.normalized()) if velocity.length_squared() > 1.0 else 1.0
	var slip_angle := rad_to_deg(acos(clampf(slip_cos, -1.0, 1.0)))
	var is_moving_forward := velocity.dot(transform.x) > 100.0
	var is_drifting := is_moving_forward and (absf(rad_to_deg(steer_direction)) >= 75.0 or slip_angle >= 25.0) and velocity.length() > 450.0
	
	_drift_l.emitting = is_drifting
	_drift_r.emitting = is_drifting

## Called by the network sync to update this remote car's state.
func apply_sync(pos: Vector2, rot: float, vel: Vector2, steer: float) -> void:
	_sync_pos   = pos
	_sync_rot   = rot
	_sync_vel   = vel
	_sync_steer = steer
	_has_sync_data = true


func _create_drift_particles() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.emitting = false
	p.amount = 15
	p.lifetime = 0.5
	p.local_coords = false
	p.gravity = Vector2.ZERO
	p.direction = Vector2(-1, 0)
	p.show_behind_parent = true
	p.spread = 20.0
	p.initial_velocity_min = 20.0
	p.initial_velocity_max = 60.0
	
	var tex := GradientTexture2D.new()
	tex.width = 32
	tex.height = 32
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	var tg := Gradient.new()
	tg.add_point(0.0, Color.WHITE)
	tg.add_point(1.0, Color(1, 1, 1, 0.0))
	tex.gradient = tg
	p.texture = tex
	
	p.scale_amount_min = 1.5
	p.scale_amount_max = 3.0
	
	var grad := Gradient.new()
	grad.add_point(0.0, Color(0.9, 0.9, 0.9, 0.6))
	grad.add_point(1.0, Color(0.9, 0.9, 0.9, 0.0))
	p.color_ramp = grad
	
	return p

func _push_npc_hits() -> void:
	var hit_wall = false
	for i in get_slide_collision_count():
		var body := get_slide_collision(i).get_collider()
		if body != null:
			if body.is_in_group("npc"):
				if body.has_method("receive_player_hit"):
					# Only penalize the player if they were actually driving fast!
					if velocity.length() > 300.0:
						body.receive_player_hit(self, get_slide_collision(i))
						var main_node = get_parent()
						if main_node and main_node.has_method("report_npc_crash"):
							main_node.report_npc_crash(player_id - 1, body.global_position)
			else:
				hit_wall = true
				
	if hit_wall:
		velocity *= 0.98 # Friction from scraping against a wall

func apply_friction(delta):
	if acceleration == Vector2.ZERO and velocity.length() < 50:
		velocity = Vector2.ZERO
	var friction_force = velocity * friction * delta
	var drag_force = velocity * velocity.length() * drag * delta
	acceleration += drag_force + friction_force
	
func get_input():
	var turn = Input.get_axis(_action_left, _action_right)
	steer_direction = turn * deg_to_rad(steering_angle)
	
	if Input.is_action_pressed(_action_accel):
		acceleration = transform.x * engine_power
	if Input.is_action_pressed(_action_brake):
		acceleration = transform.x * braking
	
func calculate_steering(delta):
	var rear_wheel = position - transform.x * wheel_base / 2.0
	var front_wheel = position + transform.x * wheel_base / 2.0
	rear_wheel += velocity * delta
	front_wheel += velocity.rotated(steer_direction) * delta
	
	var new_heading = rear_wheel.direction_to(front_wheel)
	var traction = traction_slow
	if velocity.length() > slip_speed:
		traction = traction_fast
	var d = new_heading.dot(velocity.normalized())
	if d > 0:
		velocity = lerp(velocity, new_heading * velocity.length(), traction * delta)
	if d < 0:
		velocity = -new_heading * min(velocity.length(), max_speed_reverse)
	rotation = new_heading.angle()
