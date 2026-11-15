extends Node

## Stage B3.2 + B4 — investment income & social mobility tests. Run with:
##   godot --headless --path <project> tests/test_mobility.tscn
##
## Verifies:
##  1. promotion_with_demand — laborer→artisan fires when SoL high + savings
##     buffer + artisan shortage (unmet demand). Count + savings transfer
##     proportionally; source goes on cooldown.
##  2. promotion_without_demand_blocked — laborer→artisan BLOCKED when artisan
##     industry exists but no shortage (supply covers demand). Solves the
##     "сотни рабочих становятся ремесленниками без мастерских" problem.
##  3. demotion_fires — artisan→laborer fires when SoL low + savings exhausted.
##  4. cooldown_blocks_repeat_transition — after a transition the source Pop
##     is on cooldown for 4 weeks; a 2nd immediate call does nothing, and the
##     5th call (cooldown expired) fires again.
##  5. drift_zero_with_mobility_and_investment — 35-day full-world sim:
##     total_money conserved (|drift| < 1.0) with investment income + mobility
##     + employment + wages + migration all active.
##  6. investment_income_conserved — rich Pops earn 0.5%/wk, middle 0.1%/wk,
##     poor 0; income drawn from market.fund; when fund can't cover the total
##     payout every payout scales down (no money created).

const BAKERY_RECIPE := {"id":"bakery","name":"Bakery","inputs":{"corn":1},"outputs":{"bread":1},"workers_required":10,"daily_capacity":18,"daily_wages":22,"daily_maintenance":5,"profession_required":"artisan"}

# Market prices used to compute the relative savings thresholds. The exact
# values don't matter — what matters is that the basket cost is derivable and
# the promotion/demotion gates react to savings relative to it.
const PRICES := {
	"bread": 2.0, "corn": 1.5, "fruits": 3.0, "sugar": 4.0,
	"textiles": 8.0, "tobacco": 6.0, "rum": 5.0, "metal_goods": 10.0,
}

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_promotion_with_demand()
	ok = ok and test_promotion_without_demand_blocked()
	ok = ok and test_demotion_fires()
	ok = ok and test_cooldown_blocks_repeat_transition()
	ok = ok and test_drift_zero_with_mobility_and_investment()
	ok = ok and test_investment_income_conserved()
	print("\n=== %s ===" % ("ALL MOBILITY TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Build a town with a market seeded with all basket goods at known prices,
## so the mobility system's relative savings thresholds are computable.
func _build_town(tid: String) -> Town:
	var t := Town.new(tid, tid)
	for good_id in PRICES.keys():
		t.market.add_good(String(good_id), float(PRICES[good_id]), 0.1, 100.0, 0.0)
	WorldState.towns.append(t)
	return t

## laborer (SoL 0.9, savings buffer > 12 weeks) → artisan, because the town
## has a bakery wanting 20 artisans but only 5 available (shortage). 0.2% of
## the laborer Pop (2 people out of 1000) promotes; count + savings move
## proportionally; laborer goes on 4-week cooldown; totals conserved.
func test_promotion_with_demand() -> bool:
	WorldState.reset()
	var t := _build_town("t_promo")
	# laborer: 1000 people, savings 2000 (per-capita 2.0 >> 12-week basket
	# cost ~0.61 → buffer satisfied), high SoL.
	var laborer := Pop.new("p_lab", "t_promo", "poor", "laborer", 1000.0)
	laborer.savings = 2000.0
	laborer.living_standard = 0.9
	# artisan: only 5 people — bakery wants 20 → unmet demand (shortage).
	var artisan := Pop.new("p_art", "t_promo", "middle", "artisan", 5.0)
	artisan.savings = 0.0
	t.pops.append(laborer)
	t.pops.append(artisan)
	# Bakery requires artisan, target_workers 20 > supply 5 → shortage.
	var ind := Industry.new("bakery1", "bakery", "t_promo", 10.0, 3000.0, "town:t_promo")
	ind.target_workers = 20.0
	t.industries.append(ind)
	var recipes := {"bakery": BAKERY_RECIPE}
	var mob := SocialMobilitySystem.new()
	var total_count_before: float = laborer.count + artisan.count
	var total_sav_before: float = laborer.savings + artisan.savings
	mob.update_social_mobility(t, recipes)
	var passed: bool = true
	var detail: String = ""
	if laborer.count >= 1000.0:
		passed = false
		detail = "laborer did not shrink (count=%.2f, expect <1000)" % laborer.count
	elif artisan.count <= 5.0:
		passed = false
		detail = "artisan did not grow (count=%.2f, expect >5)" % artisan.count
	elif laborer.mobility_cooldown != SocialMobilitySystem.MOBILITY_COOLDOWN_WEEKS:
		passed = false
		detail = "cooldown not set (=%d, expect %d)" % [laborer.mobility_cooldown, SocialMobilitySystem.MOBILITY_COOLDOWN_WEEKS]
	elif abs((laborer.count + artisan.count) - total_count_before) > 0.001:
		passed = false
		detail = "count not conserved (before=%.2f after=%.2f)" % [total_count_before, laborer.count + artisan.count]
	elif abs((laborer.savings + artisan.savings) - total_sav_before) > 0.001:
		passed = false
		detail = "savings not conserved (before=%.2f after=%.2f)" % [total_sav_before, laborer.savings + artisan.savings]
	else:
		# Expected: ~2 people + ~4 savings moved (0.2% of 1000 / 2000).
		var moved_count: float = 1000.0 - laborer.count
		var moved_sav: float = 2000.0 - laborer.savings
		detail = "laborer 1000→%.2f artisan 5→%.2f moved_count=%.2f moved_sav=%.2f cooldown=%d (conserved)" % [laborer.count, artisan.count, moved_count, moved_sav, laborer.mobility_cooldown]
	_report("promotion_with_demand", passed, detail)
	return passed

## laborer with high SoL + savings, but artisan supply (100) covers bakery
## demand (20) → NO shortage → promotion BLOCKED. laborer stays laborer even
## when prosperous, because there are no unfilled artisan jobs.
func test_promotion_without_demand_blocked() -> bool:
	WorldState.reset()
	var t := _build_town("t_nodem")
	var laborer := Pop.new("p_lab", "t_nodem", "poor", "laborer", 1000.0)
	laborer.savings = 2000.0
	laborer.living_standard = 0.9
	# artisan: 100 people — bakery wants only 20 → supply covers demand →
	# has_unmet_demand("artisan") is false → promotion blocked.
	var artisan := Pop.new("p_art", "t_nodem", "middle", "artisan", 100.0)
	artisan.savings = 0.0
	t.pops.append(laborer)
	t.pops.append(artisan)
	var ind := Industry.new("bakery1", "bakery", "t_nodem", 10.0, 3000.0, "town:t_nodem")
	ind.target_workers = 20.0
	t.industries.append(ind)
	var recipes := {"bakery": BAKERY_RECIPE}
	var mob := SocialMobilitySystem.new()
	var laborer_before: float = laborer.count
	var artisan_before: float = artisan.count
	mob.update_social_mobility(t, recipes)
	var passed: bool = abs(laborer.count - laborer_before) < 0.001 and abs(artisan.count - artisan_before) < 0.001
	var detail: String = "laborer=%.2f→%.2f artisan=%.2f→%.2f (expect NO change: no artisan shortage)" % [laborer_before, laborer.count, artisan_before, artisan.count]
	_report("promotion_without_demand_blocked", passed, detail)
	return passed

## artisan with SoL 0.2 + savings exhausted (< 1 week basket cost) → demotes
## to laborer. 0.5% of the artisan Pop demotes; count + savings transfer
## proportionally; artisan goes on cooldown; totals conserved.
func test_demotion_fires() -> bool:
	WorldState.reset()
	var t := _build_town("t_dem")
	# artisan: 500 people, savings 10 → per-capita 0.02, well under 1 week
	# of middle-basket consumption (~0.09) → capital exhausted. SoL 0.2.
	var artisan := Pop.new("p_art", "t_dem", "middle", "artisan", 500.0)
	artisan.savings = 10.0
	artisan.living_standard = 0.2
	# laborer: target role for the demotion.
	var laborer := Pop.new("p_lab", "t_dem", "poor", "laborer", 100.0)
	laborer.savings = 0.0
	t.pops.append(artisan)
	t.pops.append(laborer)
	var mob := SocialMobilitySystem.new()
	var total_count_before: float = artisan.count + laborer.count
	var total_sav_before: float = artisan.savings + laborer.savings
	mob.update_social_mobility(t, {})
	var passed: bool = true
	var detail: String = ""
	if artisan.count >= 500.0:
		passed = false
		detail = "artisan did not shrink (count=%.2f, expect <500)" % artisan.count
	elif laborer.count <= 100.0:
		passed = false
		detail = "laborer did not grow (count=%.2f, expect >100)" % laborer.count
	elif artisan.mobility_cooldown != SocialMobilitySystem.MOBILITY_COOLDOWN_WEEKS:
		passed = false
		detail = "cooldown not set (=%d)" % artisan.mobility_cooldown
	elif abs((artisan.count + laborer.count) - total_count_before) > 0.001:
		passed = false
		detail = "count not conserved (before=%.2f after=%.2f)" % [total_count_before, artisan.count + laborer.count]
	elif abs((artisan.savings + laborer.savings) - total_sav_before) > 0.001:
		passed = false
		detail = "savings not conserved (before=%.4f after=%.4f)" % [total_sav_before, artisan.savings + laborer.savings]
	else:
		var moved_count: float = 500.0 - artisan.count
		detail = "artisan 500→%.2f laborer 100→%.2f moved_count=%.2f cooldown=%d (conserved)" % [artisan.count, laborer.count, moved_count, artisan.mobility_cooldown]
	_report("demotion_fires", passed, detail)
	return passed

## Cooldown: a source Pop that just transitioned can't transition again for
## 4 weeks. Call 1 fires (cooldown set to 4); calls 2-4 are blocked (cooldown
## decrements 3→2→1); call 5 (cooldown reaches 0) fires again. So over 5
## weekly calls exactly 2 transitions happen.
func test_cooldown_blocks_repeat_transition() -> bool:
	WorldState.reset()
	var t := _build_town("t_cool")
	var laborer := Pop.new("p_lab", "t_cool", "poor", "laborer", 10000.0)
	laborer.savings = 50000.0
	laborer.living_standard = 0.9
	var artisan := Pop.new("p_art", "t_cool", "middle", "artisan", 5.0)
	artisan.savings = 0.0
	t.pops.append(laborer)
	t.pops.append(artisan)
	var ind := Industry.new("bakery1", "bakery", "t_cool", 10.0, 3000.0, "town:t_cool")
	# Huge target_workers (5000) so the artisan shortage PERSISTS across the
	# promotions (artisan supply starts at 5, grows by ~20/call, stays far
	# below 5000 for the whole test). This isolates the cooldown as the ONLY
	# thing blocking calls 2-4 — otherwise call 1 would resolve the shortage
	# and call 5 would be blocked by demand, not by cooldown (which is its own
	# correct behavior, tested separately in promotion_without_demand_blocked).
	ind.target_workers = 5000.0
	t.industries.append(ind)
	var recipes := {"bakery": BAKERY_RECIPE}
	var mob := SocialMobilitySystem.new()
	mob.update_social_mobility(t, recipes)   # call 1 — fires
	var after_call1: float = laborer.count
	var passed: bool = true
	var detail: String = ""
	if after_call1 >= 10000.0:
		passed = false
		detail = "call 1 did not fire (laborer=%.2f, expect <10000)" % after_call1
	# Calls 2, 3, 4 — cooldown decrements 4→3→2→1, all blocked. laborer count
	# must stay frozen at after_call1 (no other growth system is running).
	mob.update_social_mobility(t, recipes)   # call 2 — blocked (cooldown 3)
	var after_call2: float = laborer.count
	mob.update_social_mobility(t, recipes)   # call 3 — blocked (cooldown 2)
	mob.update_social_mobility(t, recipes)   # call 4 — blocked (cooldown 1)
	var after_call4: float = laborer.count
	if abs(after_call2 - after_call1) > 0.001 or abs(after_call4 - after_call1) > 0.001:
		passed = false
		detail = "cooldown did not block: after1=%.2f after2=%.2f after4=%.2f (expect all equal)" % [after_call1, after_call2, after_call4]
	# Call 5 — cooldown reaches 0, eligible again, fires.
	mob.update_social_mobility(t, recipes)   # call 5 — fires (cooldown was 1→0)
	var after_call5: float = laborer.count
	if passed and after_call5 >= after_call4:
		passed = false
		detail = "call 5 did not fire after cooldown expired: after4=%.2f after5=%.2f (expect after5 < after4)" % [after_call4, after_call5]
	if passed:
		var transitions: int = 2   # call 1 + call 5
		detail = "call1=%.2f (fired) call2-4=%.2f (frozen, cooldown) call5=%.2f (fired again) → %d transitions in 5 weeks" % [after_call1, after_call4, after_call5, transitions]
	_report("cooldown_blocks_repeat_transition", passed, detail)
	return passed

## Full-world 35-day sim with investment income + social mobility + employment
## + wages + migration all wired into the weekly tick. total_money must be
## conserved (|drift| < 1.0). This is the integration conservation check.
func test_drift_zero_with_mobility_and_investment() -> bool:
	WorldState.build_world()
	var engine := SimulationEngine.new()
	var money_before: float = WorldState.total_money()
	engine.run_days(35)   # 5 weekly ticks — mobility + investment fire several times
	var money_after: float = WorldState.total_money()
	var drift: float = money_after - money_before
	var passed: bool = abs(drift) < 1.0
	# Also confirm mobility actually happened somewhere in the world (at least
	# one Pop on cooldown, or profession counts shifted). This guards against
	# the system silently no-op'ing.
	var on_cooldown: int = 0
	for t in WorldState.towns:
		for p in t.pops:
			if p.mobility_cooldown > 0:
				on_cooldown += 1
	var detail: String = "money=%.1f→%.1f drift=%.4f pops_on_cooldown=%d (need |drift|<1)" % [money_before, money_after, drift, on_cooldown]
	if passed and on_cooldown == 0:
		# Not a hard failure (mobility is rare: 0.2%/wk, needs high SoL + savings
		# + demand), but worth flagging if it never fires in 5 weeks.
		detail += " [warning: no Pop on cooldown — mobility may not have fired]"
	_report("drift_zero_with_mobility_and_investment", passed, detail)
	return passed

## Investment income: rich 0.5%/wk, middle 0.1%/wk, poor 0. Drawn from
## market.fund → pop.savings, conserved. When the fund can't cover the total
## payout, every payout scales down (no money created).
func test_investment_income_conserved() -> bool:
	WorldState.reset()
	var t := _build_town("t_inv")
	var rich := Pop.new("p_rich", "t_inv", "rich", "planter", 10.0)
	rich.savings = 1000.0
	var middle := Pop.new("p_mid", "t_inv", "middle", "merchant", 50.0)
	middle.savings = 500.0
	var poor := Pop.new("p_poor", "t_inv", "poor", "laborer", 100.0)
	poor.savings = 100.0
	t.pops.append(rich)
	t.pops.append(middle)
	t.pops.append(poor)
	t.market.fund = 5000.0   # plenty to cover the payout
	var pop_sys := PopulationSystem.new()
	var total_before: float = rich.savings + middle.savings + poor.savings + t.market.fund
	pop_sys.apply_investment_income(t)
	var expected_rich_gain: float = 1000.0 * PopulationSystem.INVESTMENT_RATE_RICH    # 5.0
	var expected_mid_gain: float = 500.0 * PopulationSystem.INVESTMENT_RATE_MIDDLE    # 0.5
	var expected_poor_gain: float = 0.0
	var total_after: float = rich.savings + middle.savings + poor.savings + t.market.fund
	var passed: bool = true
	var detail: String = ""
	if abs((rich.savings - 1000.0) - expected_rich_gain) > 0.001:
		passed = false
		detail = "rich gain wrong: %.4f (expect %.4f)" % [rich.savings - 1000.0, expected_rich_gain]
	elif abs((middle.savings - 500.0) - expected_mid_gain) > 0.001:
		passed = false
		detail = "middle gain wrong: %.4f (expect %.4f)" % [middle.savings - 500.0, expected_mid_gain]
	elif abs(poor.savings - 100.0) > 0.001:
		passed = false
		detail = "poor should not earn: poor.savings=%.4f (expect 100.0, no gain)" % poor.savings
	elif abs(total_after - total_before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [total_before, total_after]
	else:
		# Now test the fund-limit case: huge savings, tiny fund → payout scaled.
		rich.savings = 100000.0
		middle.savings = 0.0
		poor.savings = 0.0
		t.market.fund = 100.0   # can't cover rich's 500 payout
		var limited_before: float = rich.savings + t.market.fund
		pop_sys.apply_investment_income(t)
		var limited_after: float = rich.savings + t.market.fund
		# Fund should be drained to 0, rich gains exactly 100 (the available).
		var fund_drained: bool = abs(t.market.fund) < 0.001
		var rich_gain: float = rich.savings - 100000.0
		var scaled_ok: bool = abs(rich_gain - 100.0) < 0.001
		var limited_conserved: bool = abs(limited_after - limited_before) < 0.001
		if not (fund_drained and scaled_ok and limited_conserved):
			passed = false
			detail = "fund-limit case wrong: fund=%.4f rich_gain=%.4f conserved=%s" % [t.market.fund, rich_gain, limited_conserved]
		else:
			detail = "rich +%.2f middle +%.2f poor +%.2f (rates %.3f/%.3f/0); fund-limit: rich +%.2f fund→0; conserved" % [expected_rich_gain, expected_mid_gain, expected_poor_gain, PopulationSystem.INVESTMENT_RATE_RICH, PopulationSystem.INVESTMENT_RATE_MIDDLE, rich_gain]
	_report("investment_income_conserved", passed, detail)
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
