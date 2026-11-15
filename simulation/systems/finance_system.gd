class_name FinanceSystem
extends RefCounted

## Daily wages + maintenance, and per-industry profit accounting.
##
## Wages and maintenance are paid proportionally to utilisation
## (produced_batches / capacity) — an idle line costs nothing in Stage 1, so a
## money-starved industry can restart the moment prices turn profitable again
## (no death spiral from fixed idle cost).
##
## Stage B2: wages are multiplied by [param Town.wage_rate[profession]],
## which is adjusted weekly by [param PopulationSystem.adjust_wages] based
## on demand/supply for each profession. A labour shortage (demand > supply)
## → wage_rate > 1.0 → industries pay more. Surplus → wage_rate < 1.0 → less.
##
## Money flow (unchanged direction, only amounts change):
##   wages      -> industry.money down, population_money up
##   maintenance-> industry.money down, market.fund up (local services)

func charge_wages(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var cap: float = float(recipe.get("daily_capacity", 1.0))
		# Stage B2: multiply base wages by per-profession wage_rate.
		var prof: String = String(recipe.get("profession_required", "laborer"))
		var wage_rate: float = float(t.wage_rate.get(prof, 1.0))
		var wages_daily: float = float(recipe.get("daily_wages", 0.0)) * wage_rate
		var maint_daily: float = float(recipe.get("daily_maintenance", 0.0))
		var util: float = ind.produced_batches / cap if cap > 0.0 else 0.0
		var wages: float = wages_daily * util
		var maint: float = maint_daily * util
		ind.money -= wages + maint
		# Stage B3: wages go to the Pop of matching profession (not aggregate).
		t.add_to_pop(prof, wages)
		t.market.fund += maint
		ind.last_wages = wages
		ind.last_maintenance = maint
		# Stage 4: rent (set by charge_rent, which runs just before charge_wages
		# in the daily tick) is subtracted as a production cost alongside wages.
		ind.last_profit = ind.last_revenue - ind.last_input_cost - wages - maint - ind.last_rent

## Stage 4 (land rent): crop-producing plantations pay rent to the local
## planter Pop. Rent is a production cost (like wages/maintenance), deducted
## BEFORE profit — it reflects the landowner's claim on the land the plantation
## operates on, distinct from dividends (the owner's claim on the enterprise).
## Rent = RENT_RATE × actual daily revenue ([param ind.last_revenue], set in
## ProductionSystem.produce), so a drought or glut that cuts output also cuts
## rent. Only the 6 agricultural CROP_GOODS pay rent; lumber_camp and mine are
## extractive (no planter class, no land rent — their surplus stays in
## dividends). Recipient: the town's planter Pop (aggregated class income, not
## per-capita; individual plots are not modelled). If the town has no planter
## Pop, the rent flows to market.fund via Town.add_to_pop_or_fund, which
## returns the credited amount — so "rent charged == rent credited" always
## holds and WorldState.total_money is conserved (drift=0).
## Money flow: industry.money -> planter Pop.savings (or market.fund).
const RENT_RATE: float = 0.06   # 6% of actual crop revenue; tuned via sim

func charge_rent(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		if not _produces_crop(recipe):
			ind.last_rent = 0.0
			continue
		var rent: float = ind.last_revenue * RENT_RATE
		# Rent is junior to solvency: never push the industry below zero.
		rent = min(rent, ind.money)
		ind.money -= rent
		ind.last_rent = rent
		ind.weekly_rent += rent
		t.add_to_pop_or_fund("planter", rent)

## True if the recipe outputs a land-based agricultural crop — the same set
## [param ProductionSystem.CROP_GOODS] marks as drought-affected. These (and
## only these) pay land rent: corn/fruits/sugar_cane/tobacco/hemp/cotton.
func _produces_crop(recipe: Dictionary) -> bool:
	var outputs: Dictionary = recipe.get("outputs", {})
	for good_id in outputs.keys():
		if ProductionSystem.CROP_GOODS.has(String(good_id)):
			return true
	return false

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
		# Stage B3: dividends to all Pops proportionally (town-owned = public).
		t.add_to_all_pops(payout)
	elif oid == "player":
		var c: Company = WorldState.get_company("player")
		if c != null:
			c.money += payout
		else:
			t.add_to_all_pops(payout)
	elif oid.begins_with("ai:"):
		var co_id: String = oid.substr(3)
		var c: Company = WorldState.get_company(co_id)
		if c != null:
			c.money += payout
		else:
			t.add_to_all_pops(payout)
	elif oid.begins_with("state:"):
		var sid: String = oid.substr(6)
		var st: State = WorldState.get_state(sid)
		if st != null:
			st.treasury += payout
		else:
			t.add_to_all_pops(payout)
	elif oid.begins_with("entrepreneur:"):
		t.add_to_all_pops(payout)
	else:
		t.add_to_all_pops(payout)

# Generic account transfer, used by Stage 2 trade (player <-> market.fund).
# Stage 1 leaves it as a documented no-op so the contract is visible.
func transfer_money(_t: Town, _from: String, _to: String, _amount: float) -> bool:
	return false
