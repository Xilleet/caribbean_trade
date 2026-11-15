class_name WeeklyTick
extends RefCounted

## One simulation week. Runs per-town: profit book → dividends → population
## growth → employment → wage adjustment. Stage B2b also runs migration
## pressure computation across ALL towns (migration needs to see all towns
## to find best destinations — so it's called once per week, not per-town).

var population_system: PopulationSystem
var finance_system: FinanceSystem
var migration_system: MigrationSystem
var recipes: Dictionary
var rng: RandomNumberGenerator
var _migration_done_this_week: bool = false

func _init(p_pop: PopulationSystem, p_fin: FinanceSystem, p_mig: MigrationSystem, p_recipes: Dictionary, p_rng: RandomNumberGenerator) -> void:
	population_system = p_pop
	finance_system = p_fin
	migration_system = p_mig
	recipes = p_recipes
	rng = p_rng

func run(t: Town) -> void:
	# Close the weekly profit book for each industry BEFORE adjusting workers,
	# distribute dividends to recirculate hoarded cash, then start a new week.
	for ind in t.industries:
		ind.weekly_profit = ind.money - ind.money_start_of_week
		ind.money_start_of_week = ind.money
	finance_system.distribute_profits(t, recipes)
	population_system.update_population(t, rng)
	# Stage B2: profession-based hiring + wage adjustment.
	population_system.update_employment(t, recipes)
	population_system.adjust_wages(t, recipes)
	# Stage B2b: migration pressure — computed once per week across ALL towns.
	# Uses _migration_done_this_week flag so it only runs on the first town
	# of the week (all towns are iterated in SimulationEngine.step_week).
	if not _migration_done_this_week:
		migration_system.compute_migration(WorldState.towns)
		_migration_done_this_week = true

## Called by SimulationEngine at the end of step_week to reset the weekly flag.
func reset_weekly() -> void:
	_migration_done_this_week = false
