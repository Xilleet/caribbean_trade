class_name FinanceSystem
extends RefCounted

## Daily wages + maintenance, and per-industry profit accounting.
##
## Wages and maintenance are paid proportionally to utilisation
## (produced_batches / capacity) — an idle line costs nothing in Stage 1, so a
## money-starved industry can restart the moment prices turn profitable again
## (no death spiral from fixed idle cost).
##
## Money flow:
##   wages      -> industry.money down, population_money up
##   maintenance-> industry.money down, market.fund up (local services)

func charge_wages(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var cap: float = float(recipe.get("daily_capacity", 1.0))
		var wages_daily: float = float(recipe.get("daily_wages", 0.0))
		var maint_daily: float = float(recipe.get("daily_maintenance", 0.0))
		var util: float = ind.produced_batches / cap if cap > 0.0 else 0.0
		var wages: float = wages_daily * util
		var maint: float = maint_daily * util
		ind.money -= wages + maint
		t.population_money += wages
		t.market.fund += maint
		ind.last_wages = wages
		ind.last_maintenance = maint
		ind.last_profit = ind.last_revenue - ind.last_input_cost - wages - maint

func calculate_profit(ind: Industry) -> float:
	return ind.last_profit

## Weekly dividend payout. Without this, profitable raw-good producers hoard
## cash (revenue >> wages) while the population starves and the market fund
## spirals negative. Each industry keeps a working-capital reserve equal to
## 2 days of full-capacity operating cost at current prices (so it can always
## afford tomorrow's inputs) and pays the rest out to the town's population as
## dividends/owner spending. This is what recirculates money in the model.
func distribute_profits(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var cap: float = float(recipe.get("daily_capacity", 1.0))
		var wages_daily: float = float(recipe.get("daily_wages", 0.0))
		var maint_daily: float = float(recipe.get("daily_maintenance", 0.0))
		var input_cost_per_batch: float = 0.0
		var inputs: Dictionary = recipe.get("inputs", {})
		for good_id in inputs.keys():
			var qty: float = float(inputs[good_id])
			if t.market.has_good(good_id):
				input_cost_per_batch += qty * t.market.get_entry(good_id).current_price
		var daily_full_cost: float = input_cost_per_batch * cap + wages_daily + maint_daily
		var reserve: float = max(300.0, 2.0 * daily_full_cost)
		if ind.money > reserve:
			var payout: float = ind.money - reserve
			ind.money -= payout
			t.population_money += payout

# Generic account transfer, used by Stage 2 trade (player <-> market.fund).
# Stage 1 leaves it as a documented no-op so the contract is visible.
func transfer_money(_t: Town, _from: String, _to: String, _amount: float) -> bool:
	return false
