extends Camera2D

var trauma := 0.0
var max_offset := Vector2(20.0, 20.0)
var max_roll := 0.05
var decay := 0.8
var _noise_y := 0.0

func _process(delta: float) -> void:
	if trauma > 0:
		trauma = max(trauma - decay * delta, 0.0)
		_noise_y += delta * 50.0
		var amount = pow(trauma, 2.0)
		var offset_x = max_offset.x * amount * randf_range(-1.0, 1.0)
		var offset_y = max_offset.y * amount * randf_range(-1.0, 1.0)
		offset = Vector2(offset_x, offset_y)
		rotation = max_roll * amount * randf_range(-1.0, 1.0)
	else:
		offset = Vector2.ZERO
		rotation = 0.0

func add_trauma(amount: float) -> void:
	trauma = min(trauma + amount, 1.0)
