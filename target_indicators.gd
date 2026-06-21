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
		var world_target := house_pos + Vector2(0, -200)
		var screen_pos := (world_target - cam.global_position) * cam.zoom + center
		
		# Check if it's on screen to avoid drawing way offscreen
		var is_offscreen = false
		var rect = vp.get_visible_rect()
		var pad = 60.0
		var padded_rect = rect.grow(-pad)
		
		if not padded_rect.has_point(screen_pos):
			is_offscreen = true
			var dir = (screen_pos - center).normalized()
			var t_x = 10000.0
			if dir.x > 0: t_x = (padded_rect.position.x + padded_rect.size.x - center.x) / dir.x
			elif dir.x < 0: t_x = (padded_rect.position.x - center.x) / dir.x
			
			var t_y = 10000.0
			if dir.y > 0: t_y = (padded_rect.position.y + padded_rect.size.y - center.y) / dir.y
			elif dir.y < 0: t_y = (padded_rect.position.y - center.y) / dir.y
			
			var t = minf(t_x, t_y)
			screen_pos = center + dir * t
			
		var color : Color = main_ref._player_colors[player_idx % 4]
		
		var rot = 0.0
		if is_offscreen:
			rot = (world_target - cam.global_position).angle() - PI/2.0
			
		var tf = Transform2D(rot, screen_pos)
		
		var p1 : Vector2 = tf * Vector2(0, bounce)
		var p2 : Vector2 = tf * Vector2(-arrow_size/2.0, -arrow_size + bounce)
		var p3 : Vector2 = tf * Vector2(arrow_size/2.0, -arrow_size + bounce)
		
		# Draw outline and fill
		var pts := PackedVector2Array([p1, p2, p3])
		draw_colored_polygon(pts, color)
		
		var outline_pts := PackedVector2Array([p1, p2, p3, p1])
		draw_polyline(outline_pts, Color.WHITE, 4.0, true)
