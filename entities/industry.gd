class_name Industry
extends RefCounted

## A production facility. Stores state only; all economic logic lives in the
## [ProductionSystem] / [FinanceSystem]. State fields are mutated by systems,
## never recomputed from scratch in a getter, so a saved game round-trips.

var id: String
var recipe_id: String
var town_id: String
var workers: float = 0.0
var money: float = 0.0
var efficiency: float = 1.0

# Per-day plan/output (set by ProductionSystem).
var planned_batches: float = 0.0
var produced_batches: float = 0.0

# Per-day financials (set by ProductionSystem / FinanceSystem).
var last_revenue: float = 0.0
var last_input_cost: float = 0.0
var last_wages: float = 0.0
var last_maintenance: float = 0.0
var last_profit: float = 0.0

# Weekly feedback.
var money_start_of_week: float = 0.0
var weekly_profit: float = 0.0

func _init(p_id: String, p_recipe_id: String, p_town_id: String, p_workers: float, p_money: float) -> void:
	id = p_id
	recipe_id = p_recipe_id
	town_id = p_town_id
	workers = p_workers
	money = p_money
