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
		# Stage C8.1: routine maintenance repairs wear proportionally to util
		# (idle: no maint paid, no repair — symmetric with accrual in produce).
		# maint_coverage = 1.0 in Stage 1 (maint always paid in full — no death
		# spiral from underpaying maint; gating arrives in C3/C4). Forward-ready:
		# when C3/C4 gates maint by money, maint_coverage < 1 → underfunded
		# industries repair less → wear climbs faster. Capital modernization
		# (C8.2 expansion) resets wear to 0; routine maint only slows the drift
		# (net +WEAR_RATE − REPAIR_RATE = +0.001/day at full util).
		var maint_coverage: float = 1.0
		ind.wear = clampf(ind.wear - Industry.REPAIR_RATE * maint_coverage * util, 0.0, 1.0)
		# last_profit is now computed in charge_rent (which runs AFTER wages in
		# the daily tick) so it includes the current day's rent — see charge_rent.

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
		if _produces_crop(recipe):
			var rent: float = ind.last_revenue * RENT_RATE
			# Stage 4 rework: rent is the MOST JUNIOR claim — wages + maintenance
			# were paid first (charge_wages ran just before this in the daily
			# tick). Rent is capped at whatever cash remains, floored at zero:
			# an industry that can't cover wages pays no rent (the landowner
			# bears the shortfall, not the workers). Never pushes money negative.
			rent = min(rent, max(0.0, ind.money))
			ind.money -= rent
			ind.last_rent = rent
			ind.weekly_rent += rent
			t.add_to_pop_or_fund("planter", rent)
		else:
			ind.last_rent = 0.0
		# last_profit computed here (after wages in charge_wages AND rent here)
		# so all five cost components are the current day's values. charge_wages
		# no longer computes it (it ran before rent, so last_rent would be stale).
		ind.last_profit = ind.last_revenue - ind.last_input_cost - ind.last_wages - ind.last_maintenance - ind.last_rent

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
		# Stage 4 rework: reserve must cover ALL regular daily costs — inputs,
		# wages at the CURRENT wage_rate (not just the base recipe wage), maint,
		# AND expected land rent (last_revenue × RENT_RATE for crop industries).
		# Otherwise an industry could pay dividends leaving a reserve that
		# ignores rent, then can't pay the landlord the next day.
		var reserve: float = _operating_reserve(t, ind, recipe)
		# Stage C8.2: a self-financing industry (town/entrepreneur-owned) with an
		# expansion signal accumulates expansion_cost ON TOP of the operating
		# reserve (instead of paying it out as dividends), so it can self-fund
		# the next expansion in process_expansion. Player/AI/state don't raise
		# reserve here — their dividends flow to the owner wallet, and expansion
		# debits that wallet directly (player via request_expansion only; AI/state
		# via process_expansion). Building industries don't raise — no double
		# accumulation.
		if ind.expansion_weeks_left == 0 and ind.weekly_profit > 0.0 and \
				_is_self_financing(ind) and _expansion_signal(ind, recipe, t.market):
			reserve += ind.expansion_cost(recipe)
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

# ── Stage C8.2: investment & expansion ──────────────────────────────────────
# Auto-reinvest: town/state/AI industries self-expand on a shortage signal.
# Player industries expand only via request_expansion() (manual, future UI).
# Funding = capital injection owner → market.fund (construction buys local
# labour/services — conserved). Construction = EXPANSION_WEEKS weekly ticks;
# completion raises capacity_level AND resets wear (modernization).
const PLAYER_WORKING_CAPITAL: float = 2000.0   # floor under player/AI wallet when funding expansion
const STATE_RESERVE: float = 5000.0            # floor under state treasury when funding expansion

## The operating reserve an industry must keep for daily costs (inputs + wages
## at current wage_rate + maint + expected rent for crop industries). Extracted
## from distribute_profits so process_expansion can check town-owned
## affordability without duplicating the formula. Reserve = max(300, 2× daily
## full-capacity cost) — 2 days of operating headroom.
func _operating_reserve(t: Town, ind: Industry, recipe: Dictionary) -> float:
	var cap: float = float(recipe.get("daily_capacity", 1.0))
	var prof: String = String(recipe.get("profession_required", "laborer"))
	var wage_rate: float = float(t.wage_rate.get(prof, 1.0))
	var wages_daily: float = float(recipe.get("daily_wages", 0.0)) * wage_rate
	var maint_daily: float = float(recipe.get("daily_maintenance", 0.0))
	var input_cost_per_batch: float = 0.0
	var inputs: Dictionary = recipe.get("inputs", {})
	for good_id in inputs.keys():
		var qty: float = float(inputs[good_id])
		if t.market.has_good(good_id):
			input_cost_per_batch += qty * t.market.get_entry(good_id).current_price
	var expected_rent: float = (ind.last_revenue * RENT_RATE) if _produces_crop(recipe) else 0.0
	var daily_full_cost: float = input_cost_per_batch * cap + wages_daily + maint_daily + expected_rent
	return max(300.0, 2.0 * daily_full_cost)

## Stage C8.2: the auto-reinvest trigger — true when ANY output good is in
## shortage (stock < half target) AND its price is elevated (>120% of base).
## Both together = strong unmet demand → expanded capacity will find buyers.
## Either alone is insufficient: low stock + low price = weak demand; high
## price + high stock = transient spike. A chain's bottleneck good gates the
## whole chain (its shortage signals upstream to expand).
func _expansion_signal(ind: Industry, recipe: Dictionary, m: Market) -> bool:
	var outputs: Dictionary = recipe.get("outputs", {})
	for good_id in outputs.keys():
		if m.has_good(good_id):
			var e: Market.Entry = m.get_entry(good_id)
			if e.stock < e.target_stock * 0.5 and e.current_price > e.base_price * 1.2:
				return true
	return false

## Stage C8.2: town-owned (and entrepreneur-fallback) industries self-finance
## expansions from retained earnings — their dividends go to all Pops (no
## single debitable wallet), so the industry itself must hold the capital
## (raised reserve in distribute_profits). Player/AI/state have a single
## debitable owner account (Company.money / State.treasury).
func _is_self_financing(ind: Industry) -> bool:
	var oid: String = ind.owner_id
	return oid == "" or oid.begins_with("town:") or oid.begins_with("entrepreneur:")

## Stage C8.2: weekly expansion pass. Runs in WeeklyTick right after
## distribute_profits (so the reserve raise for self-financing has kept the
## cash). For each industry:
##   - building (expansion_weeks_left > 0): count down weekly; on 0, complete
##     (capacity_level += 1, wear = 0 — modernization resets C8.1's accumulated
##     wear, the capital sink routine maintenance couldn't close).
##   - not building + non-player-owner + expansion signal + profitable +
##     owner can afford: fund the expansion (debit owner → market.fund,
##     conserved) and start construction.
## Player-owned industries are skipped — they expand only via
## request_expansion() (manual override, no profitability gate).
func process_expansion(t: Town, recipes: Dictionary) -> void:
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		if ind.expansion_weeks_left > 0:
			ind.expansion_weeks_left -= 1
			if ind.expansion_weeks_left <= 0:
				ind.expansion_weeks_left = 0
				ind.capacity_level += 1
				ind.wear = 0.0   # modernization resets accumulated wear
			continue
		if ind.owner_id == "player":
			continue   # player expands via request_expansion() only
		if not _expansion_signal(ind, recipe, t.market):
			continue
		if ind.weekly_profit <= 0.0:
			continue
		var cost: float = ind.expansion_cost(recipe)
		if _try_fund_expansion(t, ind, recipe, cost):
			ind.expansion_weeks_left = Industry.EXPANSION_WEEKS
			t.market.fund += cost   # construction spending recirculates locally (conserved)

## Stage C8.2: debit the expansion cost from the owner account. Self-financing
## (town/entrepreneur): debit retained earnings (ind.money) only if it holds
## the cost ABOVE the operating reserve (distribute_profits raised the reserve
## so it should). AI/state: debit the owner wallet/treasury above its working
## floor (don't drain a company/state to zero on one expansion). Player: same
## wallet/floor check (reached only via request_expansion). Returns true if
## funded; false leaves the industry untouched (no debit, no expansion).
## Drift-safe: every debit is mirrored by a market.fund credit in the caller.
func _try_fund_expansion(t: Town, ind: Industry, recipe: Dictionary, cost: float) -> bool:
	if _is_self_financing(ind):
		var reserve: float = _operating_reserve(t, ind, recipe)
		if ind.money >= reserve + cost:
			ind.money -= cost
			return true
		return false
	var oid: String = ind.owner_id
	if oid == "player":
		var c: Company = WorldState.get_company("player")
		if c != null and c.money - PLAYER_WORKING_CAPITAL >= cost:
			c.money -= cost
			return true
		return false
	if oid.begins_with("ai:"):
		var c: Company = WorldState.get_company(oid.substr(3))
		if c != null and c.money - PLAYER_WORKING_CAPITAL >= cost:
			c.money -= cost
			return true
		return false
	if oid.begins_with("state:"):
		var st: State = WorldState.get_state(oid.substr(6))
		if st != null and st.treasury - STATE_RESERVE >= cost:
			st.treasury -= cost
			return true
		return false
	return false

## Stage C8.2: player-triggered expansion (for the future UI "Expand" button).
## Unlike auto-reinvest (process_expansion — gates on shortage signal AND
## profitability AND skips player-owned), this lets the player FORCE an
## expansion of a player-owned industry regardless of market signal — the
## player decides to grow. Still requires: player-owned, not already building,
## and the player wallet covers the cost above PLAYER_WORKING_CAPITAL. Returns
## true if construction started. Stub: wired + tested; UI button arrives in C2.
func request_expansion(ind: Industry, recipes: Dictionary, t: Town) -> bool:
	if ind.owner_id != "player":
		return false
	if ind.expansion_weeks_left > 0:
		return false
	var recipe: Dictionary = recipes.get(ind.recipe_id, {})
	var cost: float = ind.expansion_cost(recipe)
	if _try_fund_expansion(t, ind, recipe, cost):
		ind.expansion_weeks_left = Industry.EXPANSION_WEEKS
		t.market.fund += cost
		return true
	return false
