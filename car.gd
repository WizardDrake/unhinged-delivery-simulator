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
var steer_direction

## Which player controls this car: 1 or 2.
## Set by main.gd before the first physics frame.
var player_id : int = 1

## When true, the car ignores all input and doesn't move.
var frozen : bool = true

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


func _physics_process(delta):
	if frozen:
		velocity = Vector2.ZERO
		return

	acceleration = Vector2.ZERO
	get_input()
	apply_friction(delta)
	calculate_steering(delta)
	velocity += acceleration * delta
	move_and_slide()
	_push_npc_hits()


func _push_npc_hits() -> void:
	for i in get_slide_collision_count():
		var body := get_slide_collision(i).get_collider()
		if body != null and body.is_in_group("npc") and body.has_method("receive_player_hit"):
			body.receive_player_hit(self, get_slide_collision(i))

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
#	velocity = new_heading * velocity.length()
	rotation = new_heading.angle()
