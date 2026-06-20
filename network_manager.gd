extends Node

## Lightweight P2P networking manager using Godot's ENetMultiplayerPeer.
## Autoloaded as "NetworkManager".

signal player_connected(id: int)
signal player_disconnected(id: int)
signal connection_failed()
signal connection_succeeded()
signal game_starting(settings: Dictionary)

const DEFAULT_PORT := 9456
const MAX_CLIENTS := 3  # up to 3 other players (4 total)

var is_host   := false
var is_online := false
var peer_id   := 0       # our own multiplayer unique id

var connected_peers : Array[int] = []
var peer_to_player_idx : Dictionary = {}

var _peer : ENetMultiplayerPeer


func host_game(port: int = DEFAULT_PORT) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		push_error("Failed to create server: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	is_host   = true
	is_online = true
	peer_id   = multiplayer.get_unique_id() # 1 for host
	connected_peers.clear()
	peer_to_player_idx.clear()
	peer_to_player_idx[peer_id] = 0 # host is always player 0
	print("[Net] Hosting on port %d  (peer_id=%d)" % [port, peer_id])
	return OK


func join_game(ip: String, port: int = DEFAULT_PORT) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, port)
	if err != OK:
		push_error("Failed to create client: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = _peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	is_host   = false
	is_online = true
	peer_id   = 0  # not known until connected
	connected_peers.clear()
	peer_to_player_idx.clear()
	print("[Net] Connecting to %s:%d …" % [ip, port])
	return OK


func disconnect_game() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null

	# Disconnect any lingering signal connections
	for sig_name in ["peer_connected", "peer_disconnected",
					  "connected_to_server", "connection_failed"]:
		var sig : Signal = multiplayer.get(sig_name)
		for conn in sig.get_connections():
			if conn["callable"].get_object() == self:
				sig.disconnect(conn["callable"])

	is_host   = false
	is_online = false
	peer_id   = 0
	connected_peers.clear()
	peer_to_player_idx.clear()
	print("[Net] Disconnected.")


## Host tells the clients to start the game with these settings.
@rpc("authority", "call_remote", "reliable")
func _rpc_start_game(settings: Dictionary) -> void:
	# Received on the client
	GameSettings.round_time     = settings.get("round_time", 300.0)
	GameSettings.engine_power   = settings.get("engine_power", 1500.0)
	GameSettings.braking_power  = settings.get("braking_power", 1350.0)
	GameSettings.steering_angle = settings.get("steering_angle", 20.0)
	GameSettings.is_online      = true
	GameSettings.is_host        = false
	GameSettings.network_seed   = settings.get("map_seed", 0)
	GameSettings.peer_to_player_idx = settings.get("peer_to_player_idx", {})
	GameSettings.player_count   = settings.get("player_count", 2)
	game_starting.emit(settings)


## Called by the host to broadcast "start" to the clients and transition locally.
func start_online_game(seed_val: int) -> void:
	var settings := {
		"round_time":     GameSettings.round_time,
		"engine_power":   GameSettings.engine_power,
		"braking_power":  GameSettings.braking_power,
		"steering_angle": GameSettings.steering_angle,
		"map_seed":       seed_val,
		"peer_to_player_idx": peer_to_player_idx,
		"player_count":   peer_to_player_idx.size(),
	}
	# Tell the clients
	_rpc_start_game.rpc(settings)

	# Set local state
	GameSettings.is_online    = true
	GameSettings.is_host      = true
	GameSettings.network_seed = seed_val
	GameSettings.peer_to_player_idx = peer_to_player_idx
	GameSettings.player_count = peer_to_player_idx.size()

	# Transition
	get_tree().change_scene_to_file("res://main.tscn")


# ── Callbacks ─────────────────────────────────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	if not connected_peers.has(id):
		connected_peers.append(id)
	
	if is_host:
		# Assign next available player_idx (1, 2, or 3)
		var next_idx = peer_to_player_idx.size()
		peer_to_player_idx[id] = next_idx
		
	print("[Net] Peer connected: %d" % id)
	player_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	print("[Net] Peer disconnected: %d" % id)
	connected_peers.erase(id)
	if is_host:
		peer_to_player_idx.erase(id)
	player_disconnected.emit(id)


func _on_connected_to_server() -> void:
	peer_id   = multiplayer.get_unique_id()
	if not connected_peers.has(1):
		connected_peers.append(1) # server is always 1
	print("[Net] Connected to server!  (our peer_id=%d)" % peer_id)
	connection_succeeded.emit()


func _on_connection_failed() -> void:
	print("[Net] Connection failed.")
	is_online = false
	connection_failed.emit()
