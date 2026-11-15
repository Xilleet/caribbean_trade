class_name ProductionSystem
extends RefCounted

## Industry planning + input purchasing + output production.
##
## Per industry, per day:
##   1. planned_batches = min(capacity_batches, affordable_batches)
##      but ONLY if (a) the output buffer is not already in glut and
##      (b) revenue_per_batch >= cost_per_batch (break-even gate —
##      unprofitable industries idle rather than burn cash).
##   2. buy inputs from the market (limited by stock & money).
##   3. produced_batches = planned * (min input fulfilment ratio).
##   4. sell outputs into the market.
## Inputs with no recipe inputs (raw goods) skip purchasing and produce at
## full planned_batches.

const GLUT_FACTOR: float = 2.5  # stop producing when output stock > 2.5 * target
# Stage 6: goods whose producers a drought cuts (raw crops/plantations).
# Processed food (bread, rum) starves indirectly via its input, so it is not
# listed here.
# Stage C7: "sugar" replaced with "sugar_cane" — sugar is now a processed
# intermediate (sugar_mill takes sugar_cane → sugar), and sugar_plantation
# outputs sugar_cane. Drought still cuts the plantation (raw crop); sugar_mill
# is not directly affected but starves when sugar_cane is in shortage.
const CROP_GOODS := ["corn", "fruits", "sugar_cane", "tobacco", "hemp", "cotton"]

var market_system: MarketSystem

func _init(p_market_system: MarketSystem) -> void:
	market_system = p_market_system

func reset_daily_stats(t: Town) -> void:
	for ind in t.industries:
		ind.last_revenue = 0.0
		ind.last_input_cost = 0.0
		ind.last_wages = 0.0
		ind.last_maintenance = 0.0
		ind.last_profit = 0.0
		ind.last_rent = 0.0
		ind.produced_batches = 0.0

# Step 2 (plan): compute planned_batches, add input demand to the market.
func calculate_input_demand(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var cap_batches: float = _capacity_batches(ind, recipe)
		var cost_per_batch: float = _cost_per_batch(ind, recipe, t.market)
		var revenue_per_batch: float = _revenue_per_batch(ind, recipe, t.market)
		# Two gates before planning production:
		#  1. Glut: don't produce if the output buffer is already overflowing
		#     (caps raw-good overproduction — a raw good whose min price still
		#     exceeds its labour cost would otherwise accumulate forever).
		#  2. Break-even: produce only if revenue covers cost (processed goods
		#     idle instead of burning cash when inputs are too expensive).
		var glut: bool = _output_glut(ind, recipe, t.market)
		if glut:
			ind.planned_batches = 0.0
		elif cost_per_batch > 0.0 and revenue_per_batch < cost_per_batch:
			ind.planned_batches = 0.0
		else:
			var affordable: float = ind.money / cost_per_batch if cost_per_batch > 0.0 else cap_batches
			ind.planned_batches = min(cap_batches, affordable)
		var inputs: Dictionary = recipe.get("inputs", {})
		for good_id in inputs.keys():
			if t.market.has_good(good_id):
				var qty_per_batch: float = float(inputs[good_id])
				var e: Market.Entry = t.market.get_entry(good_id)
				e.daily_demand_ind += ind.planned_batches * qty_per_batch
				e.daily_demand += ind.planned_batches * qty_per_batch

# Step 3: buy inputs (money: industry -> market.fund).
func purchase_inputs(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var inputs: Dictionary = recipe.get("inputs", {})
		ind.last_input_cost = 0.0
		if inputs.is_empty():
			ind.produced_batches = ind.planned_batches
			continue
		var bought_ratio: float = 1.0
		var total_cost: float = 0.0
		for good_id in inputs.keys():
			var qty_per_batch: float = float(inputs[good_id])
			var want: float = ind.planned_batches * qty_per_batch
			var res: Dictionary = market_system.buy(t.market, good_id, want, ind.money - total_cost)
			total_cost += float(res["cost"])
			var r: float = float(res["qty"]) / want if want > 0.0 else 1.0
			bought_ratio = min(bought_ratio, r)
		ind.money -= total_cost
		t.market.fund += total_cost
		ind.last_input_cost = total_cost
		ind.produced_batches = ind.planned_batches * bought_ratio

# Step 4: produce outputs and sell them (money: market.fund -> industry).
func produce(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var outputs: Dictionary = recipe.get("outputs", {})
		for good_id in outputs.keys():
			var qty: float = float(outputs[good_id]) * ind.produced_batches
			if qty <= 0.0:
				continue
			var res: Dictionary = market_system.sell(t.market, good_id, qty)
			var revenue: float = float(res["revenue"])
			ind.money += revenue
			t.market.fund -= revenue
			ind.last_revenue += revenue
			if t.market.has_good(good_id):
				t.market.get_entry(good_id).daily_supply += qty

func _capacity_batches(ind: Industry, recipe: Dictionary) -> float:
	var cap: float = float(recipe.get("daily_capacity", 1.0))
	var req_workers: float = float(recipe.get("workers_required", 1.0))
	var worker_ratio: float = clamp(ind.workers / req_workers, 0.0, 1.0)
	# Stage 6: a drought cuts the harvest of crop-producing industries only.
	var drought: float = WorldState.drought_multiplier(ind.town_id) if _produces_crop(recipe) else 1.0
	return cap * worker_ratio * ind.efficiency * drought

func _produces_crop(recipe: Dictionary) -> bool:
	var outputs: Dictionary = recipe.get("outputs", {})
	for good_id in outputs.keys():
		if CROP_GOODS.has(String(good_id)):
			return true
	return false

func _output_glut(ind: Industry, recipe: Dictionary, m: Market) -> bool:
	# True if ANY output good's stock already exceeds GLUT_FACTOR * its target.
	# target_stock is yesterday's value (updated at end of each day), which is
	# fine for a "don't pile up more" decision.
	var outputs: Dictionary = recipe.get("outputs", {})
	for good_id in outputs.keys():
		if m.has_good(good_id):
			var e: Market.Entry = m.get_entry(good_id)
			if e.stock > e.target_stock * GLUT_FACTOR:
				return true
	return false

func _cost_per_batch(ind: Industry, recipe: Dictionary, m: Market) -> float:
	var inputs: Dictionary = recipe.get("inputs", {})
	var input_cost: float = 0.0
	for good_id in inputs.keys():
		var qty: float = float(inputs[good_id])
		if m.has_good(good_id):
			input_cost += qty * m.get_entry(good_id).current_price
	var cap: float = float(recipe.get("daily_capacity", 1.0))
	var wages_per_batch: float = float(recipe.get("daily_wages", 0.0)) / cap
	var maint_per_batch: float = float(recipe.get("daily_maintenance", 0.0)) / cap
	return input_cost + wages_per_batch + maint_per_batch

func _revenue_per_batch(ind: Industry, recipe: Dictionary, m: Market) -> float:
	var outputs: Dictionary = recipe.get("outputs", {})
	var rev: float = 0.0
	for good_id in outputs.keys():
		var qty: float = float(outputs[good_id])
		if m.has_good(good_id):
			rev += qty * m.get_entry(good_id).current_price
	return rev
