class_name WeeklyTick
extends RefCounted

## One simulation week. Runs per-town: profit book → dividends → investment
## income (B3.2) → officials' salary (Stage 1) → population growth → social
## mobility (B4) → employment → wage adjustment → migration. Stage B2b also
## runs migration pressure computation across ALL towns (migration needs to see
## all towns to find best destinations — so it's called once per week, not
## per-town). Officials' salary is likewise once-per-week (it iterates states,
## not towns).
##
## Weekly order (B4 + Stage 1 design):
##   1. distribute_profits (recirculate hoarded industry cash)
##   2. apply_investment_income  (B3.2: rich/middle earn on savings, from fund)
##   2b. pay_officials           (Stage 1: state.treasury -> official Pops)
##   3. update_population        (demography — grows/shrinks by SoL)
##   4. update_social_mobility   (B4: profession + stratum transitions)
##   5. update_employment        (hire from the post-mobility profession mix)
##   6. adjust_wages             (wage_rate reacts to new demand/supply)
##   7. compute_migration        (once per week, across all towns)
## Investment income + officials' salary run before population growth so rich
## Pops' savings are topped up for the week's daily consumption (keeps their
## SoL from collapsing). Mobility runs before employment so freshly-promoted
## artisans are immediately hireable by bakeries/distilleries in the same week.

var population_system: PopulationSystem
var finance_system: FinanceSystem
var migration_system: MigrationSystem
var social_mobility_system: SocialMobilitySystem   # Stage B4
var profession_income_system: ProfessionIncomeSystem   # Stage 1 (officials)
var recipes: Dictionary
var rng: RandomNumberGenerator
var _migration_done_this_week: bool = false
var _officials_done_this_week: bool = false

func _init(p_pop: PopulationSystem, p_fin: FinanceSystem, p_mig: MigrationSystem,
		p_mob: SocialMobilitySystem, p_prof_income: ProfessionIncomeSystem,
		p_recipes: Dictionary, p_rng: RandomNumberGenerator) -> void:
	population_system = p_pop
	finance_system = p_fin
	migration_system = p_mig
	social_mobility_system = p_mob
	profession_income_system = p_prof_income
	recipes = p_recipes
	rng = p_rng

func run(t: Town) -> void:
	# Close the weekly profit book for each industry BEFORE adjusting workers,
	# distribute dividends to recirculate hoarded cash, then start a new week.
	for ind in t.industries:
		ind.weekly_profit = ind.money - ind.money_start_of_week
		ind.money_start_of_week = ind.money
		# Stage 4: reset the weekly rent accumulator for the new week.
		ind.weekly_rent = 0.0
	finance_system.distribute_profits(t, recipes)
	# Stage C8.2: expansion pass — count down/build completions for industries
	# under construction, and fund+start new expansions for eligible town/state/
	# AI industries (shortage signal + profitable + owner can afford). Runs
	# right after distribute_profits so the reserve raise for self-financing
	# industries has kept their cash for the funding debit. Player-owned
	# industries are skipped here (they expand via request_expansion()).
	finance_system.process_expansion(t, recipes)
	# Stage B3.2: passive investment income (rich 0.5%/wk, middle 0.1%/wk)
	# drawn from market.fund → pop.savings. Conserved. Runs before population
	# growth so rich Pops don't deplete savings and shrink (the B3 problem).
	population_system.apply_investment_income(t)
	# Stage 1: state officials' salary. Per-state (iterates WorldState.states),
	# so it runs once per week — guarded by _officials_done_this_week, like
	# migration below. Runs after investment income and before population
	# growth so officials' savings are topped up for the week's consumption
	# (a broke state pays nothing → officials deplete savings → B4 demotes).
	if not _officials_done_this_week:
		profession_income_system.pay_officials()
		_officials_done_this_week = true
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
	_officials_done_this_week = false
