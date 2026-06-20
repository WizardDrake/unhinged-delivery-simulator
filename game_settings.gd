extends Node

## Global game settings singleton — passed between menus and the game scene.

# Round duration in seconds
var round_time : float = 300.0

# Car tuning
var engine_power : float = 1500.0
var braking_power : float = 1350.0
var steering_angle : float = 20.0

# Network state
var is_online    : bool  = false
var is_host      : bool  = false
var network_seed : int   = 0
var player_count : int   = 2
var peer_to_player_idx : Dictionary = {}


func reset_network() -> void:
	is_online    = false
	is_host      = false
	network_seed = 0
	player_count = 2
	peer_to_player_idx.clear()
