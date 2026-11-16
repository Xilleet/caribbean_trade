extends Node

## C4 (player bankruptcy + credit) tests. Run with:
##   ./.godot_bin/godot --headless --path . res://tests/test_bankruptcy.tscn
##
## Verifies the C4 mechanic (credit_limit, bankrupt flag, state-bank loans):
##  1. credit_limit grows with fleet size (pure getter, no money moves).
##  2. money < -credit_limit → company.bankrupt = true, sim freezes next day
##     (player's step_day is a no-op once bankrupt).
##  3. take_loan moves money state.treasury -> company.money (conserved),
##     capped at the state's available treasury, recorded in loans[].
##  4. Weekly interest accrues: company.money -= interest, state.treasury +=
##     interest, total_money unchanged (drift=0).
##  5. repay_loan reduces principal, capped at owed AND at available money,
##     conserved.
##  6. C5 per-ship strand coexists: money between C5 floor (-(upkeep×7)) and
##     C4 floor (-credit_limit) → ship strands (C5) but company NOT bankrupt.
##  7. drift over 365d with a loan outstanding stays ~0 (interest + credit +
##     all economy paths conserved).

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_credit_limit_grows_with_fleet()
	ok = ok and test_hit_floor_game_over()
	ok = ok and test_take_loan_conserved()
	ok = ok and test_loan_interest_weekly()
	ok = ok and test_repay_loan_conserved()
	ok = ok and test_c5_coexistence()
	ok = ok and test_drift_365d()
	print("\n=== %s ===" % ("ALL C4 TESTS PASSED" if ok else "SOME C4 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Test 1: credit_limit is a pure getter over ship_ids.size() — grows when the
## fleet grows, no money moves. build_world gives the player exactly one ship.
func test_credit_limit_grows_with_fleet() -> bool:
	WorldState.build_world()
	var c: Company = WorldState.get_company("player")
	var base: float = c.credit_limit()
	var expected_base: float = Company.CREDIT_BASE + Company.CREDIT_PER_SHIP * 1.0
	if abs(base - expected_base) > 0.01:
		_report("credit_limit_grows_with_fleet", false,
				"1-ship limit=%.0f expected=%.0f" % [base, expected_base])
		return false
	# Simulate fleet growth by registering a second ship_id (credit_limit is a
	# pure getter — no actual ship object needed to test the formula).
	c.ship_ids.append("ship_test_extra")
	var grown: float = c.credit_limit()
	var expected_grown: float = Company.CREDIT_BASE + Company.CREDIT_PER_SHIP * 2.0
	var passed: bool = abs(grown - expected_grown) < 0.01
	_report("credit_limit_grows_with_fleet", passed,
			"2-ship limit=%.0f expected=%.0f" % [grown, expected_grown])
	return passed

## Test 2: money just below -credit_limit → end-of-day check sets bankrupt=true.
## The triggering day still completes (ticks ran); the NEXT step_day is frozen
## (early-return — money unchanged). This is the game-over state.
func test_hit_floor_game_over() -> bool:
	WorldState.build_world()
	var c: Company = WorldState.get_company("player")
	# Place money just below the credit floor. At this depth C5 has already
	# stranded all ships (money << -(upkeep×7)), so no upkeep is debited and
	# money stays put through the day's ticks — the only thing that happens is
	# the end-of-day bankruptcy flag flips.
	c.money = -c.credit_limit() - 10.0
	var money_at_trigger: float = c.money
	var engine := SimulationEngine.new()
	engine.step_day()   # the day that crosses the floor — completes, sets flag
	var bankrupt_after_day1: bool = c.bankrupt
	var money_after_day1: float = c.money
	engine.step_day()   # frozen — no ticks, money unchanged
	var money_after_day2: float = c.money
	var frozen: bool = money_after_day2 == money_after_day1
	var passed: bool = bankrupt_after_day1 and frozen
	_report("hit_floor_game_over", passed,
			"day1 bankrupt=%s money %.0f->%.0f; day2 frozen=%s money %.0f" %
			[bankrupt_after_day1, money_at_trigger, money_after_day1,
			 frozen, money_after_day2])
	return passed

## Test 3: take_loan moves money state.treasury -> company.money (conserved),
## records principal in loans[state_id]. Total money unchanged.
func test_take_loan_conserved() -> bool:
	WorldState.build_world()
	var c: Company = WorldState.get_company("player")
	var state: State = WorldState.get_state("england")   # player flies england
	var total_before: float = WorldState.total_money()
	var co_before: float = c.money
	var st_before: float = state.treasury
	var lent: float = c.take_loan(1000.0, "england")
	var total_after: float = WorldState.total_money()
	var owed: float = float(c.loans.get("england", 0.0))
	var passed: bool = abs(lent - 1000.0) < 0.01 \
		and abs(c.money - (co_before + 1000.0)) < 0.01 \
		and abs(state.treasury - (st_before - 1000.0)) < 0.01 \
		and abs(total_after - total_before) < 0.001 \
		and abs(owed - 1000.0) < 0.01
	_report("take_loan_conserved", passed,
			"lent=%.0f co %.0f->%.0f st %.0f->%.0f drift=%.4f owed=%.0f" %
			[lent, co_before, c.money, st_before, state.treasury,
			 total_after - total_before, owed])
	return passed

## Test 4: accrue_loan_interest debits company.money, credits state.treasury,
## by exactly principal × LOAN_RATE_WEEKLY. Total money unchanged (drift=0).
func test_loan_interest_weekly() -> bool:
	WorldState.build_world()
	var c: Company = WorldState.get_company("player")
	var state: State = WorldState.get_state("england")
	c.take_loan(1000.0, "england")
	var co_before: float = c.money
	var st_before: float = state.treasury
	var total_before: float = WorldState.total_money()
	# Accrue one week's interest directly (SimulationEngine.step_week calls
	# this; here we call it directly for a deterministic single-week check).
	c.accrue_loan_interest()
	var expected_interest: float = 1000.0 * Company.LOAN_RATE_WEEKLY
	var co_debit: float = co_before - c.money
	var st_credit: float = state.treasury - st_before
	var total_after: float = WorldState.total_money()
	var passed: bool = abs(co_debit - expected_interest) < 0.01 \
		and abs(st_credit - expected_interest) < 0.01 \
		and abs(total_after - total_before) < 0.001
	_report("loan_interest_weekly", passed,
			"interest=%.2f (expected %.2f) co %.0f->%.0f st %.0f->%.0f drift=%.4f" %
			[co_debit, expected_interest, co_before, c.money,
			 st_before, state.treasury, total_after - total_before])
	return passed

## Test 5: repay_loan moves money company -> state, reduces principal, capped
## at owed AND at available money. Conserved.
func test_repay_loan_conserved() -> bool:
	WorldState.build_world()
	var c: Company = WorldState.get_company("player")
	var state: State = WorldState.get_state("england")
	c.take_loan(1000.0, "england")
	var total_before: float = WorldState.total_money()
	var co_before: float = c.money
	var st_before: float = state.treasury
	var repaid: float = c.repay_loan(400.0, "england")
	var total_after: float = WorldState.total_money()
	var owed: float = float(c.loans.get("england", 0.0))
	var passed: bool = abs(repaid - 400.0) < 0.01 \
		and abs(c.money - (co_before - 400.0)) < 0.01 \
		and abs(state.treasury - (st_before + 400.0)) < 0.01 \
		and abs(total_after - total_before) < 0.001 \
		and abs(owed - 600.0) < 0.01
	_report("repay_loan_conserved", passed,
			"repaid=%.0f co %.0f->%.0f st %.0f->%.0f owed=600?=%.0f drift=%.4f" %
			[repaid, co_before, c.money, st_before, state.treasury,
			 owed, total_after - total_before])
	return passed

## Test 6: C5 per-ship strand and C4 company-wide floor coexist. Money placed
## BETWEEN them (below -(upkeep×7), above -credit_limit) → ship strands (C5)
## but company NOT bankrupt (C4 floor not crossed). Money unchanged (stranded
## ships don't debit; no player industries to move money elsewhere).
func test_c5_coexistence() -> bool:
	WorldState.build_world()
	var ship: Ship = WorldState.get_player_ship()
	var c: Company = WorldState.get_company("player")
	var c5_floor: float = -(ship.upkeep_daily * float(ShipsTick.SOFT_CREDIT_GRACE_DAYS))
	var c4_floor: float = -c.credit_limit()
	# money just below C5 floor (ship strands), well above C4 floor (no game-over).
	c.money = c5_floor - ship.upkeep_daily   # e.g. -64 for upkeep=8
	var money_before: float = c.money
	var engine := SimulationEngine.new()
	engine.step_day()
	var ship_idled: bool = ship.state == "idle"
	var co_not_bankrupt: bool = not c.bankrupt
	var money_unchanged: bool = abs(c.money - money_before) < 0.001
	var passed: bool = ship_idled and co_not_bankrupt and money_unchanged
	_report("c5_coexistence", passed,
			"c5_floor=%.0f c4_floor=%.0f money %.0f->%.0f ship=%s bankrupt=%s" %
			[c5_floor, c4_floor, money_before, c.money, ship.state, c.bankrupt])
	return passed

## Test 7: run 365 days with a loan outstanding — interest accrues weekly
## through the whole run alongside the existing economy. drift must stay ~0
## (loan + interest + credit paths all conserved). Same |drift|<1 bar as the
## other long-run conservation tests.
func test_drift_365d() -> bool:
	WorldState.build_world()
	var c: Company = WorldState.get_company("player")
	# Take a loan so weekly interest exercises the C4 conservation path across
	# the full year. 500 is small vs the player's 5000 start + trade profit,
	# so it won't trigger bankruptcy — it just adds an interest drain.
	c.take_loan(500.0, "england")
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(365)
	var drift: float = WorldState.total_money() - total_before
	var passed: bool = abs(drift) < 1.0 and not c.bankrupt
	_report("drift_365d", passed,
			"drift=%.4f over 365d with 500 loan, bankrupt=%s (expect |drift|<1, not bankrupt)" %
			[drift, c.bankrupt])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
