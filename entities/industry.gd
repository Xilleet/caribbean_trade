class_name Industry
extends RefCounted

## A production facility. Stores state only; all economic logic lives in the
## [ProductionSystem] / [FinanceSystem]. State fields are mutated by systems,
## never recomputed from scratch in a getter, so a saved game round-trips.
## The one exception is [member efficiency] — a READ-ONLY derived value
## computed from [member wear] (which IS saved state), mirroring the
## Town.population_money getter pattern: the saved state is `wear`, efficiency
## is just its projection onto [0.3, 1.0].
##
## Stage C1 (minimal): [param owner_id] identifies who owns the industry and
## therefore who receives dividends in [FinanceSystem.distribute_profits].
## Format: [code]"town:<id>"[/code] (default, preserves Stage 1–6 behavior),
## [code]"player"[/code], [code]"ai:<co_id>"[/code], [code]"state:<sid>"[/code],
## or [code]"entrepreneur:<id>"[/code]. Empty string falls back to town.
## Buy/sell of industries arrives in C2.
##
## Stage C8.1 (wear & maintenance): [member wear] ∈ [0, 1] accrues with
## utilisation in [method ProductionSystem.produce] (idle costs no wear —
## Stage 1 "idle is free" philosophy) and is repaired by routine maintenance in
## [method FinanceSystem.charge_wages]. Net at full util + full maint:
## +WEAR_RATE − REPAIR_RATE = +0.001/day → wear creeps toward 1.0 over ~2.7
## years, cutting [member efficiency] toward [constant EFFICIENCY_FLOOR] (0.3).
## Routine maintenance SLOWS wear but does not reset it — only capital
## modernization (C8.2 expansion, which resets wear to 0) does. A hard stop at
## wear ≥ 1.0 (efficiency → 0) is deferred to C3/C4 (bankruptcy) to avoid a
## death spiral (no revenue → no maint → no repair → permanent 0).

# C8.1 wear & maintenance constants.
const WEAR_RATE: float = 0.003           # wear/day accrued at full utilisation
const REPAIR_RATE: float = 0.002         # wear/day repaired at full maint coverage
const WEAR_EFFICIENCY_DROP: float = 0.7  # efficiency = 1 − wear × 0.7
const EFFICIENCY_FLOOR: float = 0.3      # min efficiency at wear = 1.0 (D2)

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
# Stage C8.1: accumulated wear ∈ [0, 1]. 0 = new, 1 = fully worn. Accrued by
# ProductionSystem.produce (per utilisation), repaired by FinanceSystem.charge_wages
# (per maintenance coverage). Saved state — the single source of truth for the
# efficiency getter below. Reset to 0 by capital modernization (C8.2 expansion).
var wear: float = 0.0
# Stage C8.1: READ-ONLY derived from wear (efficiency = 1 − wear × 0.7, clamped
# to [EFFICIENCY_FLOOR, 1.0]). Read by ProductionSystem._capacity_batches as a
# multiplier on capacity. A getter (not saved state) — mirrors
# Town.population_money: the saved state is `wear`; this is its projection.
# Round-trips because wear is saved and the formula is pure.
var efficiency: float:
	get:
		return clampf(1.0 - wear * WEAR_EFFICIENCY_DROP, EFFICIENCY_FLOOR, 1.0)
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
# Stage 4 (land rent): daily rent paid to the local planter Pop on
# crop-producing plantations. Set by FinanceSystem.charge_rent (runs after
# ProductionSystem.produce sets last_revenue, before charge_wages computes
# last_profit so rent is subtracted as a production cost).
var last_rent: float = 0.0

# Weekly feedback.
var money_start_of_week: float = 0.0
var weekly_profit: float = 0.0
# Stage 4: rent accumulated this week (sum of daily last_rent). Reset to 0
# at the weekly book close in WeeklyTick.run (mirrors money_start_of_week).
var weekly_rent: float = 0.0

func _init(p_id: String, p_recipe_id: String, p_town_id: String, p_workers: float, p_money: float, p_owner_id: String = "") -> void:
	id = p_id
	recipe_id = p_recipe_id
	town_id = p_town_id
	workers = p_workers
	money = p_money
	owner_id = p_owner_id
