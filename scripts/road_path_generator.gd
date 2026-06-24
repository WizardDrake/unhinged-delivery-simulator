extends RefCounted

const LANE_OFFSET := 350.0


static func generate_paths(map: Node2D, rng: RandomNumberGenerator, count: int) -> Array:
	var gen: RefCounted = load("res://scripts/road_path_generator.gd").new()
	return gen._generate(map, rng, count)


func _generate(map: Node2D, rng: RandomNumberGenerator, count: int) -> Array:
	var adj := _build_adjacency(map)
	if adj.is_empty():
		return []

	var paths: Array = []
	var attempts := 0
	while paths.size() < count and attempts < count * 12:
		attempts += 1
		var node_path := _build_route(adj, rng)
		if node_path.size() < 3:
			continue
		var waypoints := _nodes_to_waypoints(map, node_path)
		if waypoints.size() < 4:
			continue
		if _path_is_duplicate(paths, waypoints):
			continue
		paths.append(waypoints)

	if paths.is_empty():
		var fallback := _fallback_path(map, adj, rng)
		if not fallback.is_empty():
			paths.append(fallback)

	return paths


func _build_adjacency(map: Node2D) -> Dictionary:
	var adj: Dictionary = {}
	var cols: int = map.grid_cols
	var rows: int = map.grid_rows
	var h_segs: Array = map._h_segs
	var v_segs: Array = map._v_segs

	for r in range(rows + 1):
		for c in range(cols + 1):
			var key := Vector2i(c, r)
			var neighbors: Array[Vector2i] = []
			if r > 0 and v_segs[r - 1][c]:
				neighbors.append(Vector2i(c, r - 1))
			if r < rows and v_segs[r][c]:
				neighbors.append(Vector2i(c, r + 1))
			if c > 0 and h_segs[r][c - 1]:
				neighbors.append(Vector2i(c - 1, r))
			if c < cols and h_segs[r][c]:
				neighbors.append(Vector2i(c + 1, r))
			if not neighbors.is_empty():
				adj[key] = neighbors
	return adj


func _junction_nodes(adj: Dictionary) -> Array[Vector2i]:
	var nodes: Array[Vector2i] = []
	for key in adj.keys():
		var nbs: Array = adj[key]
		if nbs.size() >= 2:
			nodes.append(key)
	return nodes


func _build_route(adj: Dictionary, rng: RandomNumberGenerator) -> Array[Vector2i]:
	var starts := _junction_nodes(adj)
	if starts.is_empty():
		for key in adj.keys():
			starts.append(key)
	if starts.is_empty():
		return []

	var start: Vector2i = starts[rng.randi_range(0, starts.size() - 1)]
	var path: Array[Vector2i] = [start]
	var prev := Vector2i(-1, -1)
	var cur := start

	for _step in range(48):
		var neighbors: Array = adj[cur].duplicate()
		if prev.x >= 0 and neighbors.size() > 1:
			neighbors.erase(prev)
		if neighbors.is_empty():
			break

		var nxt: Vector2i = _pick_neighbor(cur, prev, neighbors, rng)
		path.append(nxt)

		if nxt == start and path.size() >= 5:
			path.pop_back()
			return path

		prev = cur
		cur = nxt

	if path.size() >= 3:
		var back: Array[Vector2i] = []
		for i in range(path.size() - 2, 0, -1):
			back.append(path[i])
		path.append_array(back)
	return path


func _pick_neighbor(cur: Vector2i, prev: Vector2i, neighbors: Array, rng: RandomNumberGenerator) -> Vector2i:
	if prev.x >= 0:
		var fwd := cur - prev
		var straight := cur + fwd
		for n in neighbors:
			if n == straight:
				return straight
	return neighbors[rng.randi_range(0, neighbors.size() - 1)]


func _nodes_to_waypoints(map: Node2D, nodes: Array[Vector2i]) -> Array[Vector2]:
	var waypoints: Array[Vector2] = []
	for i in range(nodes.size()):
		var a: Vector2i = nodes[i]
		var b: Vector2i = nodes[(i + 1) % nodes.size()]
		var c: Vector2i = nodes[(i + 2) % nodes.size()]

		if i == 0:
			waypoints.append(_lane_pos(map, a.x, a.y, b.x, b.y, true))
		waypoints.append(_lane_pos(map, a.x, a.y, b.x, b.y, false))

		var dir_ab := Vector2(b - a)
		var dir_bc := Vector2(c - b)
		if dir_ab.length_squared() > 0.0 and dir_bc.length_squared() > 0.0 and dir_ab != dir_bc:
			waypoints.append(map._world_pos(float(b.x), float(b.y)))
	return waypoints


func _lane_pos(map: Node2D, c1: int, r1: int, c2: int, r2: int, at_start: bool) -> Vector2:
	var dir := Vector2(c2 - c1, r2 - r1)
	if dir.length_squared() < 0.01:
		return map._world_pos(float(c1), float(r1))
	dir = dir.normalized()
	var offset := Vector2(dir.y, -dir.x) * LANE_OFFSET
	var node := Vector2(c1, r1) if at_start else Vector2(c2, r2)
	return map._world_pos(node.x, node.y) + offset


func _path_is_duplicate(paths: Array, waypoints: Array[Vector2]) -> bool:
	if waypoints.is_empty():
		return true
	var first: Vector2 = waypoints[0]
	for existing in paths:
		if existing.is_empty():
			continue
		if first.distance_to(existing[0]) < 80.0 and waypoints.size() == existing.size():
			return true
	return false


func _fallback_path(map: Node2D, adj: Dictionary, rng: RandomNumberGenerator) -> Array[Vector2]:
	for key in adj.keys():
		var nbs: Array = adj[key]
		if nbs.is_empty():
			continue
		var a: Vector2i = key
		var b: Vector2i = nbs[rng.randi_range(0, nbs.size() - 1)]
		return [
			_lane_pos(map, a.x, a.y, b.x, b.y, true),
			_lane_pos(map, a.x, a.y, b.x, b.y, false),
			_lane_pos(map, b.x, b.y, a.x, a.y, false),
			_lane_pos(map, a.x, a.y, b.x, b.y, true),
		]
	return []
