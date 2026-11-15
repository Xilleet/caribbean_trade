class_name WeeklyTick
extends RefCounted

## One simulation week. Runs per-town: profit book → dividends → investment
## income (B3.2) → population growth → social mobility (B4) → employment →
## wage adjustment → migration. Stage B2b also runs migration pressure
## computation across ALL towns (migration needs to see all towns to find
## best destinations — so it's called once per week, not per-town).
##
## Weekly order (B4 design):
##   1. distribute_profits (recirculate hoarded industry cash)
##   2. apply_investment_income  (B3.2: rich/middle earn on savings, from fund)
##   3. update_population        (demography — grows/shrinks by SoL)
##   4. update_social_mobility   (B4: profession + stratum transitions)
##   5. update_employment        (hire from the post-mobility profession mix)
##   6. adjust_wages             (wage_rate reacts to new demand/supply)
##   7. compute_migration        (once per week, across all towns)
## Investment income runs before population growth so rich Pops' savings are
## topped up for the week's daily consumption (keeps their SoL from
## collapsing). Mobility runs before employment so freshly-promoted artisans
## are immediately hireable by bakeries/distilleries in the same week.

var population_system: PopulationSystem
var finance_system: FinanceSystem
var migration_system: MigrationSystem
var social_mobility_system: SocialMobilitySystem   # Stage B4
var recipes: Dictionary
var rng: RandomNumberGenerator
var _migration_done_this_week: bool = false

func _init(p_pop: PopulationSystem, p_fin: FinanceSystem, p_mig: MigrationSystem,
		p_mob: SocialMobilitySystem, p_recipes: Dictionary, p_rng: RandomNumberGenerator) -> void:
	population_system = p_pop
	finance_system = p_fin
	migration_system = p_mig
	social_mobility_system = p_mob
	recipes = p_recipes
	rng = p_rng

func run(t: Town) -> void:
	# Close the weekly profit book for each industry BEFORE adjusting workers,
	# distribute dividends to recirculate hoarded cash, then start a new week.
	for ind in t.industries:
		ind.weekly_profit = ind.money - ind.money_start_of_week
		ind.money_start_of_week = ind.money
	finance_system.distribute_profits(t, recipes)
	# Stage B3.2: passive investment income (rich 0.5%/wk, middle 0.1%/wk)
	# drawn from market.fund → pop.savings. Conserved. Runs before population
	# growth so rich Pops don't deplete savings and shrink (the B3 problem).
	population_system.apply_investment_income(t)
	population_system.update_population(t, rng)
	# Stage B4: social mobility — promotion/demotion between professions and
	# strata. Runs AFTER population growth and BEFORE employment so the new
	# profession counts feed straight into hiring in the same week.
	social_mobility_system.update_social_mobility(t, recipes)
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
