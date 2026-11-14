class_name TradeRoute
extends RefCounted

## An ordered list of port stops with per-stop buy/sell rules. The ship's
## [TradeSystem] executor applies the rules at each stop — never touching
## market stock directly. Rules are self-limiting via [param threshold]:
##   buy  -> drains market surplus DOWN to the threshold (stops buying once
##           the port is no longer in surplus);
##   sell -> fills market shortage UP to the threshold (stops selling once
##           the port is no longer short).
## So a route exhausts its own arbitrage instead of flooding a market.

var id: String
var ship_id: String
var stops: Array[String] = []          # town_ids in visit order
var active: bool = true
var wait_mode: String = "continue"     # continue | wait_until_empty | wait_until_full

class StopRule:
	extends RefCounted
	var good_id: String
	var action: String = "buy"          # buy | sell
	var threshold: float = 0.0          # buy: stop when stock <= threshold; sell: stop when stock >= threshold
	var max_qty: float = 9999.0
	var price_limit: float = 0.0        # buy: max acceptable price; sell: min acceptable price; 0 = no limit
	var priority: int = 0               # lower runs first

var rules: Dictionary = {}  # town_id -> Array[StopRule]

func _init(p_id: String, p_ship_id: String) -> void:
	id = p_id
	ship_id = p_ship_id

func rules_for(town_id: String) -> Array:
	# Rules for this stop, copied and sorted by priority ascending.
	if not rules.has(town_id):
		return []
	var sorted: Array = (rules[town_id] as Array).duplicate()
	sorted.sort_custom(func(a, b) -> bool: return a.priority < b.priority)
	return sorted

func next_stop_after(town_id: String) -> String:
	var idx: int = stops.find(town_id)
	if idx < 0 or stops.is_empty():
		return town_id
	return stops[(idx + 1) % stops.size()]
