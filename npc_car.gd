extends CharacterBody2D
## NPC traffic car — follows pre-computed waypoint loops with raycast-based
## wall avoidance, smooth stuck recovery (reverse, not teleport), and proper
## collision handling for player impacts.

# ── Physics Layers (must match project settings) ─────────────────────────────
const LAYER_WORLD  := 1
const LAYER_PLAYER := 2
const LAYER_NPC    := 4

# ── Movement ─────────────────────────────────────────────────────────────────
@export var cruise_speed := 620.0
@export var acceleration := 850.0
@export var steer_rate   := 6.5      # base angular lerp rate
@export var lateral_grip := 1400.0   # cancels side-slip per second
@export var knocked_drag := 280.0    # drag while in KNOCKED state

# ── Avoidance ────────────────────────────────────────────────────────────────
@export var avoid_strength := 3.5    # how aggressively to steer around walls

# ── Constants ────────────────────────────────────────────────────────────────

# Waypoint acceptance.
const WAYPOINT_RADIUS := 220.0
const OVERSHOOT_DOT   := -50.0

# Raycast fan — 11 rays spread 150° in front of the car.
const RAY_COUNT        := 11
const RAY_SPREAD_DEG   := 150.0
const RAY_BASE_LENGTH  := 600.0    # centre ray length
const RAY_SIDE_FALLOFF := 0.45     # outermost rays are this × centre length

# Stuck recovery.
const STUCK_SPEED       := 45.0
const STUCK_TIMEOUT     := 1.2     # seconds before entering REVERSING
const REVERSE_DURATION  := 0.85
const MAX_REVERSES      := 3       # after this many, fall back to teleport

# Player collision thresholds.
const DESTROY_REL_SPEED := 700.0
const DESTROY_PLR_SPEED := 800.0
const HIT_COOLDOWN_SECS := 0.15
const KNOCK_TIME        := 1.6

# ── State Machine ────────────────────────────────────────────────────────────
enum State { CRUISING, REVERSING, KNOCKED, WRECKED }
var _state := State.CRUISING

# ── Navigation ───────────────────────────────────────────────────────────────
var _waypoints : Array[Vector2] = []
var _wp_index  := 0
var _prev_wp   := Vector2.ZERO

## Public — read by main.gd / minimap.
var graph_ref    : Node2D = null
var is_destroyed := false

# ── Raycasts (built at runtime) ──────────────────────────────────────────────
var _rays        : Array[RayCast2D] = []
var _ray_angles  : Array[float]     = []   # angle relative to forward
var _ray_lengths : Array[float]     = []

# ── Stuck recovery state ─────────────────────────────────────────────────────
var _stuck_timer       := 0.0
var _reverse_timer     := 0.0
var _reverse_steer     := 0.0
var _reverse_count     := 0
var _last_progress_pos := Vector2.ZERO

# ── Knockback state ──────────────────────────────────────────────────────────
var _knock_timer    := 0.0
var _spin_speed     := 0.0
var _hit_cooldown_t := 0.0

# ── Node references ──────────────────────────────────────────────────────────
@onready var _sprite : Sprite2D = $Sprite2D


# ══════════════════════════════════════════════════════════════════════════════
#  Lifecycle
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Random colour tint so every NPC looks different.
	_sprite.modulate = Color.from_hsv(
		randf(),
		0.3 + randf() * 0.4,
		0.75 + randf() * 0.25,
	)
	_build_raycasts()


func _physics_process(delta: float) -> void:
	if graph_ref == null or _waypoints.is_empty():
		return

	match _state:
		State.CRUISING:
			_tick_cruising(delta)
		State.REVERSING:
			_tick_reversing(delta)
		State.KNOCKED:
			_tick_knocked(delta)
		State.WRECKED:
			_tick_wrecked(delta)

	# Visual spin decay (flair after being hit).
	if absf(_spin_speed) > 0.01:
		_sprite.rotation += _spin_speed * delta
		_spin_speed = move_toward(_spin_speed, 0.0, 4.0 * delta)

	move_and_slide()
	_check_slide_collisions()

	# Wrecked cars stick to walls — kill velocity on wall contact.
	if _state == State.WRECKED and get_slide_collision_count() > 0:
		for i in get_slide_collision_count():
			var collider := get_slide_collision(i).get_collider()
			if collider is StaticBody2D:
				velocity *= 0.05
				_spin_speed *= 0.1
				break

	if _hit_cooldown_t > 0.0:
		_hit_cooldown_t -= delta


# ══════════════════════════════════════════════════════════════════════════════
#  Initialisation  (called by main.gd — same signature as before)
# ══════════════════════════════════════════════════════════════════════════════

func init_route(waypoints: Array, start_index: int, m: Node2D) -> void:
	graph_ref = m

	_waypoints.clear()
	for p in waypoints:
		_waypoints.append(p)
	if _waypoints.is_empty():
		return

	_wp_index = clampi(start_index, 0, _waypoints.size() - 1)
	position  = _waypoints[_wp_index]
	_prev_wp  = position
	_last_progress_pos = position
	_step_waypoint()

	# Face toward first target.
	# rotation = dir.angle() + π/2 makes -transform.y point along dir.
	var dir := (_current_target() - position)
	if dir.length_squared() > 1.0:
		rotation = dir.angle() + PI * 0.5


# ══════════════════════════════════════════════════════════════════════════════
#  Raycast construction
# ══════════════════════════════════════════════════════════════════════════════

func _build_raycasts() -> void:
	# Defensively remove any rays left over from the scene file.
	for child in get_children():
		if child is RayCast2D:
			child.queue_free()

	_rays.clear()
	_ray_angles.clear()
	_ray_lengths.clear()

	var half_spread := deg_to_rad(RAY_SPREAD_DEG * 0.5)

	for i in RAY_COUNT:
		var t     := float(i) / float(RAY_COUNT - 1)         # 0 → 1
		var angle := lerpf(-half_spread, half_spread, t)      # left → right

		# Centre rays are longest; outermost rays scale down.
		var edge_dist := absf(t - 0.5) * 2.0                 # 0 at centre, 1 at edge
		var length    := RAY_BASE_LENGTH * lerpf(1.0, RAY_SIDE_FALLOFF, edge_dist)

		# Forward in local space = Vector2(0, -1)  (matches -transform.y).
		var local_dir := Vector2(0, -1).rotated(angle)

		var ray := RayCast2D.new()
		ray.target_position     = local_dir * length
		ray.collision_mask      = LAYER_WORLD | LAYER_NPC
		ray.collide_with_areas  = false
		ray.collide_with_bodies = true
		ray.enabled = true
		ray.add_exception(self)
		add_child(ray)

		_rays.append(ray)
		_ray_angles.append(angle)
		_ray_lengths.append(length)


# ══════════════════════════════════════════════════════════════════════════════
#  Direction helper
# ══════════════════════════════════════════════════════════════════════════════

## The car sprite is rotated 90° in the scene, so local "up" (−Y) = visual forward.
func _forward() -> Vector2:
	return -transform.y


# ══════════════════════════════════════════════════════════════════════════════
#  Waypoint helpers
# ══════════════════════════════════════════════════════════════════════════════

func _current_target() -> Vector2:
	return _waypoints[_wp_index]


func _step_waypoint() -> void:
	if _waypoints.is_empty():
		return
	_prev_wp  = _current_target()
	_wp_index = (_wp_index + 1) % _waypoints.size()


func _advance_waypoint() -> void:
	var target    := _current_target()
	var to_target := target - position

	if to_target.length() < WAYPOINT_RADIUS:
		_step_waypoint()
		return

	# Overshoot: dot product with segment direction goes negative past the wp.
	if _prev_wp.distance_squared_to(target) > 1.0:
		var seg_dir := (target - _prev_wp).normalized()
		if to_target.dot(seg_dir) < OVERSHOOT_DOT:
			_step_waypoint()


# ══════════════════════════════════════════════════════════════════════════════
#  CRUISING — main driving state
# ══════════════════════════════════════════════════════════════════════════════

func _tick_cruising(delta: float) -> void:
	_advance_waypoint()

	var target      := _current_target()
	var to_target   := target - position
	var desired_dir := to_target.normalized()

	# Rotation that makes _forward() (= −transform.y) point at desired_dir.
	var desired_rot := desired_dir.angle() + PI * 0.5
	var angle_err   := absf(angle_difference(rotation, desired_rot))

	# ── Raycast avoidance ─────────────────────────────────────────────
	var avoid      := _compute_avoidance()
	var threat     := avoid.threat as float      # 0-1 blockage level
	var steer_bias := avoid.steer  as float      # signed offset (+ = CW)

	# ── Steering ──────────────────────────────────────────────────────
	# Urgency ramps turn speed when error is large (tight corners).
	var urgency := 1.0 + clampf(angle_err / deg_to_rad(35.0), 0.0, 1.5)

	# Blend waypoint steering with avoidance.  High threat → avoidance dominates.
	var avoid_influence := clampf(threat * 2.5, 0.0, 0.9)
	var target_rot      := desired_rot + steer_bias * avoid_influence

	rotation = lerp_angle(rotation, target_rot, steer_rate * urgency * delta)

	# ── Speed control ─────────────────────────────────────────────────
	var speed_mult := 1.0

	# Slow for sharp turns.
	if angle_err > deg_to_rad(55.0):
		speed_mult = minf(speed_mult, 0.3)
	elif angle_err > deg_to_rad(30.0):
		speed_mult = minf(speed_mult, 0.55)
	elif angle_err > deg_to_rad(15.0):
		speed_mult = minf(speed_mult, 0.8)

	# Slow for walls / obstacles ahead.
	if threat > 0.75:
		speed_mult = minf(speed_mult, 0.15)
	elif threat > 0.5:
		speed_mult = minf(speed_mult, 0.35)
	elif threat > 0.25:
		speed_mult = minf(speed_mult, 0.6)

	# Slow for nearby NPCs (group-based distance check as a safety net).
	var npc_dist := _nearest_npc_distance()
	if npc_dist < 200.0:
		speed_mult = minf(speed_mult, 0.25)
	elif npc_dist < 350.0:
		speed_mult = minf(speed_mult, 0.5)
	elif npc_dist < 500.0:
		speed_mult = minf(speed_mult, 0.75)

	var target_speed := cruise_speed * speed_mult

	# ── Velocity integration ──────────────────────────────────────────
	var fwd       := _forward()
	var fwd_speed := velocity.dot(fwd)
	fwd_speed = move_toward(fwd_speed, target_speed, acceleration * delta)

	# Cancel lateral drift (tyre grip simulation).
	var right     := fwd.rotated(PI * 0.5)
	var lat_speed := velocity.dot(right)
	lat_speed = move_toward(lat_speed, 0.0, lateral_grip * delta)

	velocity = fwd * fwd_speed + right * lat_speed

	# ── Stuck detection ───────────────────────────────────────────────
	_check_stuck(delta, fwd_speed)


# ── Avoidance computation ────────────────────────────────────────────────────

func _compute_avoidance() -> Dictionary:
	## Scans the raycast fan and returns:
	##   steer  — signed steering offset (+ = clockwise / steer right)
	##   threat — 0..1 how blocked the forward path is
	var steer_sum  := 0.0
	var max_threat := 0.0

	for i in _rays.size():
		var ray := _rays[i]
		if not ray.is_colliding():
			continue

		# Soften avoidance for NPC colliders (they can move out of the way).
		var collider := ray.get_collider()
		var is_npc: bool = collider != null and collider.is_in_group("npc")
		var weight   := 0.45 if is_npc else 1.0

		var hit_dist  := position.distance_to(ray.get_collision_point())
		var proximity := 1.0 - clampf(hit_dist / _ray_lengths[i], 0.0, 1.0)
		proximity *= proximity          # quadratic — much stronger close-range
		proximity *= weight

		# ── Steering contribution ─────────────────────────────────
		# Ray angle > 0 → obstacle is to the right → steer left  (−)
		# Ray angle < 0 → obstacle is to the left  → steer right (+)
		var steer_influence := absf(sin(_ray_angles[i])) + 0.2
		steer_sum -= sign(_ray_angles[i]) * proximity * steer_influence * avoid_strength

		# ── Threat contribution ───────────────────────────────────
		# Centre-facing rays contribute more to the "blocked" metric.
		var center_w := 1.0 - absf(sin(_ray_angles[i]))
		center_w = 0.4 + center_w * 0.6
		max_threat = maxf(max_threat, proximity * center_w)

	return { "steer": steer_sum, "threat": max_threat }


# ── Stuck recovery ────────────────────────────────────────────────────────────

func _check_stuck(delta: float, fwd_speed: float) -> void:
	var near_wp := position.distance_to(_current_target()) < WAYPOINT_RADIUS * 1.5

	if fwd_speed < STUCK_SPEED and not near_wp:
		_stuck_timer += delta
		if _stuck_timer >= STUCK_TIMEOUT:
			_stuck_timer = 0.0
			_begin_reverse()
	else:
		_stuck_timer = maxf(0.0, _stuck_timer - delta * 2.0)
		# Reset reverse counter once we've made real progress.
		if position.distance_to(_last_progress_pos) > 400.0:
			_reverse_count = 0
			_last_progress_pos = position


func _begin_reverse() -> void:
	_reverse_count += 1
	if _reverse_count > MAX_REVERSES:
		# Last resort — teleport toward the next waypoint.
		_teleport_recovery()
		_reverse_count = 0
		return

	_state         = State.REVERSING
	_reverse_timer = REVERSE_DURATION
	_reverse_steer = randf_range(-3.0, 3.0)


# ══════════════════════════════════════════════════════════════════════════════
#  REVERSING — back up and try a new angle
# ══════════════════════════════════════════════════════════════════════════════

func _tick_reversing(delta: float) -> void:
	_reverse_timer -= delta
	if _reverse_timer <= 0.0:
		_state       = State.CRUISING
		_stuck_timer = 0.0
		return

	rotation += _reverse_steer * delta
	velocity  = -_forward() * cruise_speed * 0.35


func _teleport_recovery() -> void:
	## Fallback after repeated failed reverses — teleport toward the next wp.
	_step_waypoint()
	var dir := (_current_target() - position).normalized()
	if dir.length_squared() > 0.01:
		position += dir * 180.0
		rotation  = dir.angle() + PI * 0.5
	velocity = _forward() * cruise_speed * 0.3
	_last_progress_pos = position


# ══════════════════════════════════════════════════════════════════════════════
#  KNOCKED — skidding after a player hit
# ══════════════════════════════════════════════════════════════════════════════

func _tick_knocked(delta: float) -> void:
	_knock_timer -= delta

	# Apply drag so the car skids to a halt.
	var spd := velocity.length()
	if spd > 10.0:
		var total_drag := knocked_drag + spd * 0.12
		velocity = velocity.normalized() * maxf(0.0, spd - total_drag * delta)
	else:
		velocity = Vector2.ZERO

	# Return to CRUISING once timer expires and speed is low.
	if _knock_timer <= 0.0 and spd < 60.0:
		_state           = State.CRUISING
		_spin_speed      = 0.0
		_sprite.rotation = 0.0
		_stuck_timer     = 0.0

# ══════════════════════════════════════════════════════════════════════════════
#  WRECKED — destroyed debris that can be shoved around
# ══════════════════════════════════════════════════════════════════════════════

func _tick_wrecked(delta: float) -> void:
	# Heavy drag — wrecks slide but stop fairly quickly.
	var spd := velocity.length()
	if spd > 5.0:
		var wreck_drag := 350.0 + spd * 0.2
		velocity = velocity.normalized() * maxf(0.0, spd - wreck_drag * delta)
	else:
		velocity = Vector2.ZERO


# ══════════════════════════════════════════════════════════════════════════════
#  Collision handling
# ══════════════════════════════════════════════════════════════════════════════

func _check_slide_collisions() -> void:
	for i in get_slide_collision_count():
		var col  := get_slide_collision(i)
		var body := col.get_collider()
		if body is CharacterBody2D and body.name == "Car":
			receive_player_hit(body, col)


## Called by the player car (car.gd) or by our own slide-collision check.
func receive_player_hit(player: CharacterBody2D, _collision: KinematicCollision2D) -> void:
	if _hit_cooldown_t > 0.0:
		return
	_hit_cooldown_t = HIT_COOLDOWN_SECS

	var player_speed := player.velocity.length()
	var impact_speed := (player.velocity - velocity).length()

	# ── Wrecked cars just get shoved around as debris ────────────────
	if is_destroyed:
		var push_dir := player.velocity.normalized() \
						if player_speed > 50.0 \
						else (global_position - player.global_position).normalized()
		velocity = push_dir * player_speed * 0.6
		var cross := push_dir.cross(_forward())
		_spin_speed = sign(cross) * clampf(player_speed / 500.0, 0.3, 3.0)
		return

	# ── Destruction check ────────────────────────────────────────────
	if impact_speed >= DESTROY_REL_SPEED or player_speed >= DESTROY_PLR_SPEED:
		_wreck()
		# Give the wreck an initial shove so it flies on impact.
		var push_dir := player.velocity.normalized() \
						if player_speed > 50.0 \
						else (global_position - player.global_position).normalized()
		velocity = push_dir * player_speed * 0.65
		var cross := push_dir.cross(_forward())
		_spin_speed = sign(cross) * clampf(player_speed / 400.0, 1.0, 4.0)
		return

	# ── Knockback ─────────────────────────────────────────────────────
	_state       = State.KNOCKED
	_knock_timer = KNOCK_TIME

	var push_dir := player.velocity.normalized() \
					if player_speed > 100.0 \
					else (global_position - player.global_position).normalized()
	velocity = push_dir * player_speed * 0.75

	# Visual spin proportional to the hit angle.
	var cross := push_dir.cross(_forward())
	_spin_speed = sign(cross) * clampf(player_speed / 600.0, 0.5, 2.5)


func _wreck() -> void:
	is_destroyed = true
	_state       = State.WRECKED

	var tex := load("res://assets/npc_car_destroyed.png") as Texture2D
	if tex:
		_sprite.texture = tex
	_sprite.modulate = Color(0.45, 0.45, 0.45, 0.85)


# ══════════════════════════════════════════════════════════════════════════════
#  Sensing utilities
# ══════════════════════════════════════════════════════════════════════════════

## Cheaply find the distance to the nearest alive NPC (used as a speed brake).
func _nearest_npc_distance() -> float:
	var best := INF
	for node in get_tree().get_nodes_in_group("npc"):
		if node == self or not node is Node2D:
			continue
		if "is_destroyed" in node and node.is_destroyed:
			continue
		best = minf(best, global_position.distance_to(node.global_position))
	return best
