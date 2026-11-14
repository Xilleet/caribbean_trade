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
# per-state bribe cooldown — maps state_id -> SimulationClock.week
# of the last accepted bribe. A bribe is refused while (current_week - last) < 4.
var bribe_cooldowns: Dictionary = {}

func _init(p_id: String, p_name: String, p_money: float, p_is_ai: bool = false) -> void:
        id = p_id
        name = p_name
        money = p_money
        is_ai = p_is_ai
