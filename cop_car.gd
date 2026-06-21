extends "res://npc_car.gd"

var target_player : Node2D = null

# Siren variables
var siren_timer := 0.0
var siren_state := false

func _ready() -> void:
	# _ready from npc_car.gd runs first, so we just setup our specifics
	if has_node("BootArea"):
		$BootArea.body_entered.connect(_on_boot_area_body_entered)
	
	cruise_speed = 800.0 # Patrol speed
	acceleration = 1200.0
	steer_rate = 6.0

func _physics_process(delta: float) -> void:
	if target_player != null and is_instance_valid(target_player):
		siren_timer -= delta
		if siren_timer <= 0.0:
			siren_timer = 0.15
			siren_state = !siren_state
			if siren_state:
				_sprite.modulate = Color(2.0, 0.5, 0.5)
			else:
				_sprite.modulate = Color(0.5, 0.5, 2.0)
				
		# Catchup mechanic
		var dist = global_position.distance_to(target_player.global_position)
		if dist > 1500.0:
			cruise_speed = 2500.0
		elif dist < 500.0:
			cruise_speed = 1200.0
		else:
			cruise_speed = 1800.0
	else:
		_sprite.modulate = Color(1, 1, 1) # Normal cop colors
		cruise_speed = 800.0 # Patrol speed
		
	# Call npc_car.gd's physics process!
	super._physics_process(delta)

func _current_target() -> Vector2:
	if target_player != null and is_instance_valid(target_player):
		var lead = target_player.global_position
		if "velocity" in target_player:
			lead += target_player.velocity * 0.5
		return lead
	return super._current_target()

func _advance_waypoint() -> void:
	if target_player != null and is_instance_valid(target_player):
		return # Don't advance waypoints when chasing
	super._advance_waypoint()

func _on_boot_area_body_entered(body: Node2D) -> void:
	if target_player != null and body == target_player:
		if graph_ref != null and graph_ref.has_method("boot_player"):
			graph_ref.boot_player(target_player)
			
		# After booting, reset target so it goes back to patrolling
		target_player = null
