class_name ConsumptionSystem
extends RefCounted

## Population demand + consumption.
##
## Three classes (poor / middle / rich) with different baskets and per-capita
## daily amounts. Desired quantity = headcount * per_capita. Goods are bought
## from the market in a fixed PRIORITY order (staples first), each limited by
## stock and by the population's remaining wallet — so an unobtainable luxury
## never starves the population of bread. Satisfaction = qty_bought / desired.

const BASKETS := {
	"poor":   {"bread": 0.012, "corn": 0.010, "fruits": 0.004},
	"middle": {"bread": 0.009, "corn": 0.006, "fruits": 0.008, "sugar": 0.005, "textiles": 0.0025},
	"rich":   {"bread": 0.006, "fruits": 0.010, "sugar": 0.008, "tobacco": 0.006, "rum": 0.005, "textiles": 0.004, "metal_goods": 0.003},
}

# Staples before luxuries, so the poor can always eat before the rich buy rum.
const PRIORITY = ["bread", "corn", "fruits", "sugar", "textiles", "tobacco", "rum", "metal_goods"]

var market_system: MarketSystem

func _init(p_market_system: MarketSystem) -> void:
	market_system = p_market_system

# Step 1: compute population demand, store on market entries.
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
				# Stage 6: a famine multiplies panic demand for the staple.
				demand *= WorldState.famine_demand_multiplier(t.id, String(good_id))
				e.daily_demand_pop += demand
				e.daily_demand += demand

# Step 5: buy the basket from the market in priority order (money: population
# -> market.fund). Each good is limited by stock and remaining wallet, so an
# unobtainable luxury does not crowd out staples.
func consume_goods(t: Town) -> void:
	var counts := {"poor": t.poor, "middle": t.middle, "rich": t.rich}
	var desired: Dictionary = {}
	for cls in counts.keys():
		var count: float = float(counts[cls])
		var basket: Dictionary = BASKETS[cls]
		for good_id in basket.keys():
			var q: float = count * float(basket[good_id])
			# Stage 6: a famine raises the quantity the population tries to buy
			# (panic hoarding) — more population_money -> market.fund if stock
			# allows, else a satisfaction drop. Money stays conserved either way.
			q *= WorldState.famine_demand_multiplier(t.id, String(good_id))
			desired[good_id] = float(desired.get(good_id, 0.0)) + q

	var satisfied_sum: float = 0.0
	var desired_sum: float = 0.0
	# First the prioritised goods, then any basket good not in PRIORITY.
	var order: Array = []
	for g in PRIORITY:
		order.append(g)
	for good_id in desired.keys():
		if not PRIORITY.has(good_id):
			order.append(good_id)

	for good_id in order:
		if not desired.has(good_id):
			continue
		var want: float = float(desired[good_id])
		desired_sum += want
		if want <= 0.0 or not t.market.has_good(good_id):
			continue
		var res: Dictionary = market_system.buy(t.market, good_id, want, t.population_money)
		var cost: float = float(res["cost"])
		t.population_money -= cost
		t.market.fund += cost
		satisfied_sum += float(res["qty"])

	t.satisfaction = clamp(satisfied_sum / desired_sum, 0.0, 1.0) if desired_sum > 0.0 else 1.0
