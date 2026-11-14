class_name WeeklyTick
extends RefCounted

## One simulation week. Stage 1 runs only population + employment feedback.
## The v0.1 plan also lists migration, city development, AI strategy and
## events — those are Stage 4/5 and are intentionally absent here.

var population_system: PopulationSystem
var finance_system: FinanceSystem
var recipes: Dictionary
var rng: RandomNumberGenerator

func _init(p_pop: PopulationSystem, p_fin: FinanceSystem, p_recipes: Dictionary, p_rng: RandomNumberGenerator) -> void:
	population_system = p_pop
	finance_system = p_fin
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
	population_system.update_employment(t, recipes)
