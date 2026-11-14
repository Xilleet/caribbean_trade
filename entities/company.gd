class_name Company
extends RefCounted

## A trading company (the player or, later, an AI). Stage 1 only carries the
## wallet; buy/sell/trade-route logic arrives in Stage 2 and routes every
## transaction through [MarketSystem].

var id: String
var name: String
var money: float = 0.0
var is_ai: bool = false
var ship_ids: Array[String] = []
# snapshot of money at the start of the current simulated day. The UI
# shows `money - last_day_money` as today's net wallet delta so the player can
# see where funds went (upkeep drains are otherwise invisible). Snapshotted in
# SimulationEngine.step_day before any ticks run; not read by the economy.
var last_day_money: float = 0.0
# Stage A3.1: per-state week of the last bribe (state_id -> int week). Drives
# the 4-week bribe cooldown in the Diplomacy panel and main.bribe_state. Empty
# by default (no bribes yet); not read by the economy or any existing test.
var bribe_cooldowns: Dictionary = {}

func _init(p_id: String, p_name: String, p_money: float, p_is_ai: bool = false) -> void:
	id = p_id
	name = p_name
	money = p_money
	is_ai = p_is_ai
