class_name Ship
extends RefCounted

## A trading vessel. Carries cargo between towns and executes its trade route
## at each port. Movement is discrete: each day the ship advances [param speed]
## units toward its destination; on arrival it docks, trades, and departs to
## the next stop. All stock/money mutations go through [MarketSystem] via
## [TradeSystem] — the ship never touches [Market.Entry.stock] directly.

var id: String
var owner_id: String
var ship_type: String = "sloop"
var speed: float = 14.0
var cargo_capacity: float = 60.0
var cargo_used: float = 0.0
var cargo: Dictionary = {}        # good_id -> qty
var pos: Vector2 = Vector2.ZERO
var destination_id: String = ""
var current_town_id: String = ""
var state: String = "idle"        # idle | sailing | docked
var upkeep_daily: float = 8.0
var route_id: String = ""
# Stage A1: defensive armament. 0 = merchant (full pirate risk), 1 = light
# escort (risk halved), 2 = warship (risk quartered). Pirate roll in
# ShipsTick uses effective_prob = base_prob / (1 + armed).
var armed: int = 0
# Stage 4: when true the ship auto-trades its route and departs on its own
# (headless verification, future AI ships). When false the ship only docks and
# waits — the player manually buys/sells and clicks "Отплыть" to depart.
var auto_trade: bool = true

# Per-day bookkeeping (set by ShipsTick / TradeSystem).
var days_sailing: int = 0
var last_buy_cost: float = 0.0
var last_sell_revenue: float = 0.0
var lifetime_buy_cost: float = 0.0
var lifetime_sell_revenue: float = 0.0

func _init(p_id: String, p_owner: String, p_type: String, p_speed: float, p_cap: float, p_upkeep: float) -> void:
	id = p_id
	owner_id = p_owner
	ship_type = p_type
	speed = p_speed
	cargo_capacity = p_cap
	upkeep_daily = p_upkeep

func cargo_free() -> float:
	return cargo_capacity - cargo_used

func cargo_qty(good_id: String) -> float:
	return float(cargo.get(good_id, 0.0))

func add_cargo(good_id: String, qty: float) -> void:
	if qty <= 0.0:
		return
	cargo[good_id] = cargo_qty(good_id) + qty
	cargo_used += qty

func remove_cargo(good_id: String, qty: float) -> float:
	var have: float = cargo_qty(good_id)
	var actual: float = min(have, qty)
	if actual <= 0.0:
		return 0.0
	cargo[good_id] = have - actual
	if float(cargo[good_id]) <= 0.0:
		cargo.erase(good_id)
	cargo_used -= actual
	return actual
