class_name Market
extends RefCounted

## Per-town market. Holds one [Entry] per good. The market also keeps a
## [param fund] transaction buffer: when someone buys, money flows into the
## fund; when industries sell outputs or draw maintenance, money flows out.
## population_money + sum(industry.money) + sum(market.fund) is conserved
## (external trade aside).

class Entry:
	extends RefCounted
	var good_id: String
	var stock: float = 0.0
	var base_price: float
	var min_price: float
	var max_price: float
	var current_price: float
	var daily_demand: float = 0.0       # total: population + industry inputs
	var daily_demand_pop: float = 0.0
	var daily_demand_ind: float = 0.0
	var daily_supply: float = 0.0       # industry output produced today
	var target_stock: float = 10.0
	var price_history: Array[float] = []

	func _init(p_good_id: String, p_base: float, p_min: float, p_max: float) -> void:
		good_id = p_good_id
		base_price = p_base
		min_price = p_min
		max_price = p_max
		current_price = p_base

var entries: Dictionary = {}  # good_id -> Entry
var fund: float = 0.0

func add_good(good_id: String, base: float, p_min: float, p_max: float, init_stock: float = 0.0) -> Entry:
	var e := Entry.new(good_id, base, p_min, p_max)
	e.stock = init_stock
	entries[good_id] = e
	return e

func get_entry(good_id: String) -> Entry:
	return entries[good_id]

func has_good(good_id: String) -> bool:
	return entries.has(good_id)

func reset_daily() -> void:
	for v in entries.values():
		var e: Entry = v
		e.daily_demand = 0.0
		e.daily_demand_pop = 0.0
		e.daily_demand_ind = 0.0
		e.daily_supply = 0.0
