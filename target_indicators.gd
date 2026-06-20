extends Control

var player_idx := 0
var main_ref : Node2D

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if main_ref == null or main_ref._game_state != "playing":
		return
	
	var targets : Array = main_ref._player_targets[player_idx]
	if targets.is_empty():
		return
		
	var cam : Camera2D = main_ref._cameras[player_idx]
	if cam == null:
		return
		
	var vp := get_viewport()
	var center := vp.get_visible_rect().size / 2.0
	
	var arrow_size := 50.0
	var bounce := sin(Time.get_ticks_msec() / 150.0) * 20.0
	
	for house in targets:
		if house == null or not is_instance_valid(house):
			continue
		var house_pos : Vector2 = house.global_position
		# The house center is house_pos. We want the arrow to float above it.
		var world_target := house_pos + Vector2(0, -700)
		var screen_pos := (world_target - cam.global_position) * cam.zoom + center
		
		# Check if it's on screen to avoid drawing way offscreen
		if not vp.get_visible_rect().has_point(screen_pos):
			# Maybe draw an offscreen indicator? Or just skip.
			# Let's just draw it, CanvasItem drawing handles clipping.
			pass
			
		var color : Color = main_ref._player_colors[player_idx % 4]
		var p1 := screen_pos + Vector2(0, bounce)
		var p2 := screen_pos + Vector2(-arrow_size/2.0, -arrow_size + bounce)
		var p3 := screen_pos + Vector2(arrow_size/2.0, -arrow_size + bounce)
		
		# Draw outline and fill
		var pts := PackedVector2Array([p1, p2, p3])
		draw_colored_polygon(pts, color)
		
		var outline_pts := PackedVector2Array([p1, p2, p3, p1])
		draw_polyline(outline_pts, Color.WHITE, 4.0, true)
