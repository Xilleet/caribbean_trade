class_name ConsumptionSystem
extends RefCounted

## Population demand + consumption.
##
## Stage B3: per-Pop consumption. Each Pop buys from its OWN savings
## (Pop.savings), limited by wallet AND market stock. SoL (living standard)
## = qty_bought / qty_desired per Pop. Pop.satisfaction = SoL.
## town.satisfaction is a computed getter (weighted avg of Pop.satisfaction).
##
## Three baskets by stratum (poor/middle/rich). TODO B3.1: per-profession
## baskets (e.g., sailors buy rum, servants don't) — stub for now, all
## professions within a stratum share the same basket.

const BASKETS := {
	"poor":   {"bread": 0.012, "corn": 0.010, "fruits": 0.004},
	"middle": {"bread": 0.009, "corn": 0.006, "fruits": 0.008, "sugar": 0.005, "textiles": 0.0025},
	"rich":   {"bread": 0.006, "fruits": 0.010, "sugar": 0.008, "tobacco": 0.006, "rum": 0.005, "textiles": 0.004, "metal_goods": 0.003},
}

# TODO B3.1: per-profession baskets. Currently all professions within a
# stratum share BASKETS[cls]. Future: sailors consume more rum, servants
# consume less luxury, merchants consume more textiles, etc. This will
# create per-profession consumption patterns and make Pop types feel
# distinct. Stub — implement after testing B3 baseline.

# Staples before luxuries, so the poor can always eat before the rich buy rum.
const PRIORITY = ["bread", "corn", "fruits", "sugar", "textiles", "tobacco", "rum", "metal_goods"]

var market_system: MarketSystem

func _init(p_market_system: MarketSystem) -> void:
	market_system = p_market_system

# Step 1: compute population demand, store on market entries.
# Reads t.poor/middle/rich (computed getters summing Pop.count by stratum).
# Demand is aggregate by stratum — prices react to total demand.
func calculate_demand(t: Town) -> void:
	t.market.reset_daily()
	var counts := {"poor": t.poor, "middle": t.middle, "rich": t.rich}
	for cls in counts.keys():
		var count: float = float(counts[cls])
		var basket: Dictionary = BASKETS[cls]
		for good_id in basket.keys():
			var per_capita: float = float(basket[good_id])
			var demand: float = count * per_capita
			if t.market.has_good(good_id):
				var e: Market.Entry = t.market.get_entry(good_id)
				demand *= WorldState.famine_demand_multiplier(t.id, String(good_id))
				e.daily_demand_pop += demand
				e.daily_demand += demand

# Step 5: per-Pop consumption. Each Pop buys from its OWN savings (not
# the aggregate town.population_money). Goods bought in PRIORITY order
# (staples first) so luxuries don't crowd out bread. SoL = bought / desired.
func consume_goods(t: Town) -> void:
	# Phase 1: compute desired quantities per Pop.
	var desired_per_pop: Dictionary = {}    # pop.id -> {good_id: qty}
	var desired_total_per_pop: Dictionary = {}  # pop.id -> total desired
	for p in t.pops:
		var basket: Dictionary = BASKETS.get(p.social_class, {})
		var d: Dictionary = {}
		var total: float = 0.0
		for good_id in basket.keys():
			var qty: float = p.count * float(basket[good_id])
			qty *= WorldState.famine_demand_multiplier(t.id, String(good_id))
			d[good_id] = qty
			total += qty
		desired_per_pop[p.id] = d
		desired_total_per_pop[p.id] = total

	# Phase 2: buy in priority order. For each good, iterate all Pops and
	# let each buy what it can afford from its own savings. This ensures
	# staples are bought before luxuries (bread for everyone before rum).
	var bought_per_pop: Dictionary = {}     # pop.id -> total bought
	for p in t.pops:
		bought_per_pop[p.id] = 0.0

	# Build buy order: PRIORITY first, then any basket good not in PRIORITY.
	var order: Array = []
	for g in PRIORITY:
		order.append(g)
	# Collect all unique goods from all Pops' baskets.
	var all_goods: Dictionary = {}
	for p in t.pops:
		var d: Dictionary = desired_per_pop[p.id]
		for good_id in d.keys():
			all_goods[good_id] = true
	for good_id in all_goods.keys():
		if not PRIORITY.has(String(good_id)):
			order.append(good_id)

	for good_id in order:
		var gid: String = String(good_id)
		if not t.market.has_good(gid):
			continue
		for p in t.pops:
			var d: Dictionary = desired_per_pop[p.id]
			if not d.has(gid):
				continue
			var want: float = float(d[gid])
			if want <= 0.0:
				continue
			# Buy limited by Pop's savings AND market stock.
			var res: Dictionary = market_system.buy(t.market, gid, want, p.savings)
			var cost: float = float(res["cost"])
			p.savings -= cost
			t.market.fund += cost
			bought_per_pop[p.id] = float(bought_per_pop[p.id]) + float(res["qty"])

	# Phase 3: compute SoL and satisfaction per Pop.
	for p in t.pops:
		var bought: float = float(bought_per_pop[p.id])
		var desired: float = float(desired_total_per_pop[p.id])
		if desired > 0.0:
			p.living_standard = clamp(bought / desired, 0.0, 1.0)
		else:
			p.living_standard = 1.0
		p.satisfaction = p.living_standard
	# Note: town.satisfaction is now a computed getter (weighted avg of
	# Pop.satisfaction by count) — no need to set it here.
