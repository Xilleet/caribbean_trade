class_name PopulationSystem
extends RefCounted

## Weekly population + employment + wage dynamics.
##
## Satisfaction (set daily by [ConsumptionSystem]) drives growth:
##   sat > 0.8  -> +1%/week   (boom + immigration)
##   sat < 0.5  -> -2%/week    (famine + emigration)
##   otherwise  -> mild drift around neutral
##
## Stage B2 Employment: profession-based hiring. Each industry has a
## [param profession_required] (from recipe). Industries hire from Pops
## of matching profession. If multiple industries compete for the same
## profession pool and demand > supply, they're scaled down proportionally.
## [param Pop.employed_count] is updated to track how many of each Pop
## are employed (for B3 unemployment/satisfaction).
##
## Stage B2 Wages: [method adjust_wages] runs after employment. For each
## profession, if demand (employed workers) > supply (Pop.count), wage_rate
## rises; if demand < supply, it falls. [param FinanceSystem.charge_wages]
## multiplies [param recipe.daily_wages] by [param Town.wage_rate[prof]].

const WAGE_ADJUSTMENT_RATE: float = 0.05   # 5% per week toward equilibrium
const WAGE_MIN: float = 0.5                # never below 50% of base wages
const WAGE_MAX: float = 3.0                # never above 300% of base wages

# Stage B3.2: passive investment income. Rich Pops (planter, official,
# financier) own capital — plantations, credit, land — and earn a weekly
# return on their savings. Middle Pops (merchant, small_planter) earn a
# smaller return (small business). Poor Pops live paycheck to paycheck
# and earn nothing. This keeps rich Pops from depleting savings and
# shrinking (the B3 problem: planter/official/financier had sat ~0.59 and
# were shrinking because they had no income source).
#
# Rates are weekly: 0.5% for rich (~29% simple annual, realistic for
# colonial investments), 0.1% for middle (~5% annual). The income is drawn
# from market.fund (money in circulation) so total_money is conserved —
# drift=0. If market.fund can't cover the total payout, every payout is
# scaled down proportionally (no money created).
const INVESTMENT_RATE_RICH: float = 0.005    # 0.5%/week → ~29%/year
const INVESTMENT_RATE_MIDDLE: float = 0.001  # 0.1%/week → ~5%/year

func calculate_satisfaction(t: Town) -> float:
	return t.satisfaction

## Stage B3.2: weekly passive investment income. Rich Pops earn 0.5%/week on
## savings, middle Pops 0.1%/week, poor Pops nothing. The income is drawn
## from [param t.market.fund] (money in circulation) and credited to each
## Pop's [param savings] — so [param WorldState.total_money] is conserved.
## If [param market.fund] can't cover the total payout, every payout is
## scaled down by the same ratio (no money created, drift=0 preserved).
## Called first in [param WeeklyTick.run], before population growth and
## social mobility, so rich Pops' savings are topped up for the week's
## daily consumption cycle (keeps their SoL from collapsing).
func apply_investment_income(t: Town) -> void:
	# First pass: compute the total payout we WOULD make.
	var total_income: float = 0.0
	for p in t.pops:
		var rate: float = _investment_rate_for(p.social_class)
		if rate > 0.0 and p.savings > 0.0:
			total_income += p.savings * rate
	# Nothing to pay (no rich/middle savings, or all rates zero) → done.
	if total_income <= 0.0:
		return
	# Money in circulation. If the fund is empty/stranded, there is no
	# circulating capital to pay investment returns from this week — skip
	# (the payout is deferred, not created out of thin air).
	var available: float = t.market.fund
	if available <= 0.0:
		return
	# Scale every payout by the same ratio if the fund can't cover the total.
	# This preserves the relative distribution of investment income and keeps
	# drift exactly 0 (we never credit more than we debit).
	var scale: float = 1.0 if total_income <= available else available / total_income
	for p in t.pops:
		var rate: float = _investment_rate_for(p.social_class)
		if rate <= 0.0 or p.savings <= 0.0:
			continue
		var income: float = p.savings * rate * scale
		p.savings += income
		t.market.fund -= income

## Investment return rate by stratum: rich 0.5%/week, middle 0.1%/week,
## poor 0. Poor Pops live paycheck to paycheck — no capital to invest.
func _investment_rate_for(social_class: String) -> float:
	match social_class:
		"rich":
			return INVESTMENT_RATE_RICH
		"middle":
			return INVESTMENT_RATE_MIDDLE
		_:
			return 0.0

func update_population(t: Town, _rng: RandomNumberGenerator) -> void:
	# Stage B3: per-Pop growth based on each Pop's own satisfaction (SoL).
	# High-SoL Pops grow (boom + immigration), low-SoL Pops shrink (famine
	# + emigration). Each Pop has its own growth rate — employed artisan
	# with high SoL grows, unemployed laborer with low SoL shrinks.
	for p in t.pops:
		if p.count <= 0.0:
			continue
		var sat: float = p.satisfaction
		var growth: float
		if sat > 0.8:
			growth = 0.01
		elif sat < 0.5:
			growth = -0.02
		else:
			growth = (sat - 0.65) * 0.02
		# Apply growth to this Pop's count directly (no set_class_count —
		# each Pop grows independently, ratios within stratum can change).
		p.count = max(0.0, p.count * (1.0 + growth))

## Stage B2: profession-based employment. Four phases:
##   1. Each industry sets target_workers based on weekly_profit (same logic
##      as before — hire if profitable, fire if losing money).
##   2. Group industries by profession_required, compute demand (sum of
##      target_workers) vs supply (sum of Pop.count for that profession).
##   3. If demand > supply for a profession, scale all industries of that
##      profession down proportionally. Otherwise industries get their target.
##   4. Update Pop.employed_count: for each Pop, sum the workers of all
##      industries requiring that Pop's profession.
func update_employment(t: Town, recipes: Dictionary) -> void:
	# Phase 1: set target_workers per industry (based on weekly_profit).
	# target_workers is what the industry WANTS — actual workers may be
	# lower if the profession pool is too small (Phase 3 scales down).
	# adjust_wages reads target_workers to detect shortages.
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var req: float = float(recipe.get("workers_required", 1.0))
		var target: float
		if ind.weekly_profit > 0.0:
			target = min(req * 1.5, ind.workers + 1.0)
		elif ind.weekly_profit < 0.0:
			target = max(req * 0.3, ind.workers - 1.0)
		else:
			target = ind.workers
		ind.target_workers = target

	# Phase 2: group by profession, compute demand vs supply.
	var demand_by_prof: Dictionary = {}   # prof -> sum of target_workers
	var supply_by_prof: Dictionary = {}   # prof -> sum of Pop.count
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var prof: String = String(recipe.get("profession_required", "laborer"))
		demand_by_prof[prof] = float(demand_by_prof.get(prof, 0.0)) + ind.target_workers
	for p in t.pops:
		var prof: String = p.profession
		supply_by_prof[prof] = float(supply_by_prof.get(prof, 0.0)) + p.count

	# Phase 3: assign actual workers. If demand > supply, scale down.
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var prof: String = String(recipe.get("profession_required", "laborer"))
		var demand: float = float(demand_by_prof.get(prof, 0.0))
		var supply: float = float(supply_by_prof.get(prof, 0.0))
		if demand > supply and demand > 0.0:
			ind.workers = ind.target_workers * (supply / demand)
		else:
			ind.workers = ind.target_workers

	# Phase 4: update Pop.employed_count — reset then accumulate.
	for p in t.pops:
		p.employed_count = 0.0
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var prof: String = String(recipe.get("profession_required", "laborer"))
		for p in t.pops:
			if p.profession == prof:
				p.employed_count += ind.workers
				break   # only 1 Pop per profession per town (B1 design)

## Stage B2: adjust per-profession wage rates based on demand/supply.
## Called after update_employment in WeeklyTick.run.
## For each profession present in the town:
##   ratio = employed_workers / total_pop_count
##   ratio > 1.0 → shortage → wages rise
##   ratio < 1.0 → surplus → wages fall
## Wage rate is clamped to [WAGE_MIN, WAGE_MAX] and adjusted by
## WAGE_ADJUSTMENT_RATE per week (5% of the gap toward equilibrium).
func adjust_wages(t: Town, recipes: Dictionary) -> void:
	# Collect all professions that have either demand (industries) or supply (Pops).
	var all_profs: Dictionary = {}   # prof -> true (set)
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var prof: String = String(recipe.get("profession_required", "laborer"))
		all_profs[prof] = true
	for p in t.pops:
		all_profs[p.profession] = true

	for prof in all_profs.keys():
		var prof_s: String = String(prof)
		# Demand = sum of ind.target_workers for industries requiring this
		# profession. Using target (not actual workers) because actual may
		# have been scaled down by Phase 3 — the wage signal should reflect
		# what industries WANT, not what they got.
		var demand: float = 0.0
		for ind in t.industries:
			var recipe: Dictionary = recipes[ind.recipe_id]
			if String(recipe.get("profession_required", "laborer")) == prof_s:
				demand += ind.target_workers
		# Supply = sum of Pop.count for Pops of this profession.
		var supply: float = 0.0
		for p in t.pops:
			if p.profession == prof_s:
				supply += p.count
		# Compute ratio and adjust wage_rate.
		var ratio: float = demand / supply if supply > 0.0 else 1.0
		var current: float = float(t.wage_rate.get(prof_s, 1.0))
		var new_rate: float = clamp(current + (ratio - 1.0) * WAGE_ADJUSTMENT_RATE, WAGE_MIN, WAGE_MAX)
		t.wage_rate[prof_s] = new_rate
