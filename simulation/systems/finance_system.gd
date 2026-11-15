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
##
## Stage C1 (minimal): the payout is routed by [param Industry.owner_id]:
## [code]"town:<id>"[/code] or empty → [param t.population_money] (preserves
## Stage 1–6 behavior); [code]"player"[/code] / [code]"ai:<co_id>"[/code] →
## corresponding [param Company.money]; [code]"state:<sid>"[/code] →
## [param State.treasury]; [code]"entrepreneur:<id>"[/code] → fallback to
## population (entrepreneur entity not yet modelled — arrives in later stages).
## Conservation invariant [param WorldState.total_money] is preserved in every
## branch because every target account is included in the sum.
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
			_route_dividend(t, ind, payout)

## Routes a dividend payout to the industry's owner. Stage C1 (minimal):
## routes to town.population_money (default), player company, AI company, or
## state treasury based on [param Industry.owner_id]. Unknown/entrepreneur
## owners fall back to town.population_money (safe default; conservation
## still holds because population_money is summed in total_money).
func _route_dividend(t: Town, ind: Industry, payout: float) -> void:
	var oid: String = ind.owner_id
	if oid == "" or oid.begins_with("town:"):
		t.population_money += payout
	elif oid == "player":
		var c: Company = WorldState.get_company("player")
		if c != null:
			c.money += payout
		else:
			t.population_money += payout
	elif oid.begins_with("ai:"):
		var co_id: String = oid.substr(3)
		var c: Company = WorldState.get_company(co_id)
		if c != null:
			c.money += payout
		else:
			t.population_money += payout
	elif oid.begins_with("state:"):
		var sid: String = oid.substr(6)
		var st: State = WorldState.get_state(sid)
		if st != null:
			st.treasury += payout
		else:
			t.population_money += payout
	elif oid.begins_with("entrepreneur:"):
		# C1 minimal: no entrepreneur entity exists yet. Dividends fall
		# back to town.population so money stays in circulation and
		# conservation holds. Real routing arrives when Entrepreneur
		# class is added (later stages — see README roadmap C2/C8).
		t.population_money += payout
	else:
		t.population_money += payout

# Generic account transfer, used by Stage 2 trade (player <-> market.fund).
# Stage 1 leaves it as a documented no-op so the contract is visible.
func transfer_money(_t: Town, _from: String, _to: String, _amount: float) -> bool:
	return false
