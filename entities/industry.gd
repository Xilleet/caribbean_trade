class_name Industry
extends RefCounted

## A production facility. Stores state only; all economic logic lives in the
## [ProductionSystem] / [FinanceSystem]. State fields are mutated by systems,
## never recomputed from scratch in a getter, so a saved game round-trips.
##
## Stage C1 (minimal): [param owner_id] identifies who owns the industry and
## therefore who receives dividends in [FinanceSystem.distribute_profits].
## Format: [code]"town:<id>"[/code] (default, preserves Stage 1–6 behavior),
## [code]"player"[/code], [code]"ai:<co_id>"[/code], [code]"state:<sid>"[/code],
## or [code]"entrepreneur:<id>"[/code]. Empty string falls back to town.
## Buy/sell of industries arrives in C2.

var id: String
var recipe_id: String
var town_id: String
var workers: float = 0.0
# Stage B2: target workforce (what the industry WANTS to hire, before
# profession-pool scaling). Set by PopulationSystem.update_employment
# Phase 1, read by adjust_wages to compute demand vs supply.
# If target > available workers of that profession → wage rises.
var target_workers: float = 0.0
var money: float = 0.0
var efficiency: float = 1.0
# Stage C1 (minimal): owner of the industry. Routes dividends in
# FinanceSystem.distribute_profits. Default "" = treat as town-owned
# (preserves Stage 1–6 behavior; dividends go to town.population_money).
var owner_id: String = ""

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

func _init(p_id: String, p_recipe_id: String, p_town_id: String, p_workers: float, p_money: float, p_owner_id: String = "") -> void:
	id = p_id
	recipe_id = p_recipe_id
	town_id = p_town_id
	workers = p_workers
	money = p_money
	owner_id = p_owner_id
