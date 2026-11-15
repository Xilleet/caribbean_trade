extends Node

## Stage 1 (profession income) — sailor crew wages + state officials' salary.
## Run with:
##   godot --headless --path <project> tests/test_profession_income.tscn
##
## Verifies:
##  1. crew_wage_redirect_to_home_port_sailors — ship upkeep is debited from
##     the company exactly as before, but a crew-size-proportional slice
##     (crew_size * CREW_WAGE_PER_DAY, capped at upkeep) is credited to the
##     home_port sailor Pop; the remainder stays on the upkeep town's
##     population. Total conserved (drift=0). The company pays NO second debit.
##  2. crew_wage_capped_at_upkeep — a huge crew_size makes crew_wage_owed >
##     upkeep_daily; crew_wage is capped at upkeep_daily, port_services=0, and
##     a non-sailor Pop in the upkeep town gains nothing (proves the cap binds
##     and no port-services slice leaks).
##  3. officials_paid_from_state_treasury — a state with ample treasury pays
##     each of its towns' officials OFFICIAL_SALARY_PER_CAPITA_WEEKLY;
##     treasury decreases by the same total; conserved.
##  4. officials_scale_down_on_thin_treasury — treasury < total salary bill;
##     every official's payout scales down by the same ratio; treasury drains
##     to ~0; total credited == treasury_before; conserved.
##  5. officials_nothing_when_treasury_zero — a broke state pays its officials
##     nothing; treasury and official savings unchanged.
##  6. drift_zero_365days_full_world — full-world sim with crew wages (daily,
##     via ShipsTick) + officials' salary (weekly) wired in; total_money
##     conserved (|drift| < 1.0) over 365 days.

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_crew_wage_redirect_to_home_port_sailors()
	ok = ok and test_crew_wage_capped_at_upkeep()
	ok = ok and test_officials_paid_from_state_treasury()
	ok = ok and test_officials_scale_down_on_thin_treasury()
	ok = ok and test_officials_nothing_when_treasury_zero()
	ok = ok and test_drift_zero_365days_full_world()
	print("\n=== %s ===" % ("ALL PROFESSION-INCOME TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Build a minimal ship + home town + company, run ShipsTick one day, verify
## the upkeep debit is unchanged and the crew-wage slice lands on the home
## port's sailor Pop. Town has ONLY a sailor Pop so port_services also lands
## on the sailor (clean single-account assertion).
func test_crew_wage_redirect_to_home_port_sailors() -> bool:
	WorldState.reset()
	var t := Town.new("home", "Home")
	var sailor := Pop.new("p_sail", "home", "poor", "sailor", 100.0)
	sailor.savings = 0.0
	t.pops.append(sailor)
	WorldState.towns.append(t)
	var co := Company.new("co1", "Co One", 1000.0, false)
	WorldState.companies.append(co)
	# brigantine: upkeep 16, crew_size 20 → crew_wage_owed = 20*0.3 = 6.0
	# (< upkeep 16, so not capped), port_services = 16 - 6 = 10.0.
	var ship := Ship.new("s1", "co1", "brigantine", 14.0, 140.0, 16.0)
	ship.crew_size = 20.0
	ship.home_port = "home"
	ship.current_town_id = "home"
	ship.state = "docked"
	ship.auto_trade = false   # no trade/movement — just pay upkeep
	WorldState.ships.append(ship)
	var market := MarketSystem.new()
	var trade := TradeSystem.new(market)
	var ships_tick := ShipsTick.new(trade, market)
	var before: float = co.money + sailor.savings
	ships_tick.run()
	var crew_wage: float = min(20.0 * ShipsTick.CREW_WAGE_PER_DAY, 16.0)   # 6.0
	var port_services: float = 16.0 - crew_wage                              # 10.0
	var expected_sailor: float = crew_wage + port_services                   # 16.0 (only pop)
	var after: float = co.money + sailor.savings
	var passed: bool = true
	var detail: String = ""
	if abs(co.money - (1000.0 - 16.0)) > 0.001:
		passed = false
		detail = "company debited wrong: %.4f (expect 984.0 — no second debit)" % co.money
	elif abs(sailor.savings - expected_sailor) > 0.001:
		passed = false
		detail = "sailor savings wrong: %.4f (expect %.4f = crew %.1f + port %.1f)" % [sailor.savings, expected_sailor, crew_wage, port_services]
	elif abs(after - before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [before, after]
	else:
		detail = "company -16.0 (984.0), sailor +%.1f (crew %.1f + port %.1f), drift=0" % [expected_sailor, crew_wage, port_services]
	_report("crew_wage_redirect_to_home_port_sailors", passed, detail)
	return passed

## Huge crew_size → crew_wage_owed (30) > upkeep (16) → capped at 16,
## port_services = 0. A non-sailor Pop in the upkeep town gains nothing,
## proving the cap binds and no port-services slice leaks to other Pops.
func test_crew_wage_capped_at_upkeep() -> bool:
	WorldState.reset()
	var t := Town.new("home", "Home")
	var sailor := Pop.new("p_sail", "home", "poor", "sailor", 100.0)
	sailor.savings = 0.0
	var laborer := Pop.new("p_lab", "home", "poor", "laborer", 100.0)
	laborer.savings = 0.0
	t.pops.append(sailor)
	t.pops.append(laborer)
	WorldState.towns.append(t)
	var co := Company.new("co1", "Co One", 1000.0, false)
	WorldState.companies.append(co)
	# crew_size 100 → owed 30 > upkeep 16 → crew_wage capped at 16, port=0.
	var ship := Ship.new("s1", "co1", "brigantine", 14.0, 140.0, 16.0)
	ship.crew_size = 100.0
	ship.home_port = "home"
	ship.current_town_id = "home"
	ship.state = "docked"
	ship.auto_trade = false
	WorldState.ships.append(ship)
	var market := MarketSystem.new()
	var trade := TradeSystem.new(market)
	var ships_tick := ShipsTick.new(trade, market)
	ships_tick.run()
	var passed: bool = true
	var detail: String = ""
	if abs(co.money - 984.0) > 0.001:
		passed = false
		detail = "company debited wrong: %.4f (expect 984.0)" % co.money
	elif abs(sailor.savings - 16.0) > 0.001:
		passed = false
		detail = "sailor should get full upkeep (capped): %.4f (expect 16.0)" % sailor.savings
	elif abs(laborer.savings) > 0.001:
		passed = false
		detail = "laborer should get 0 (port_services=0): %.4f" % laborer.savings
	else:
		detail = "crew_wage capped at upkeep 16.0 (owed 30), port_services=0, laborer +0"
	_report("crew_wage_capped_at_upkeep", passed, detail)
	return passed

## State with ample treasury pays its officials; treasury -= total; conserved.
func test_officials_paid_from_state_treasury() -> bool:
	WorldState.reset()
	var st := State.new("england", "England", 1000.0, 0.0)
	WorldState.states.append(st)
	var t := Town.new("t1", "T1")
	t.state_id = "england"
	var official := Pop.new("p_off", "t1", "rich", "official", 10.0)
	official.savings = 0.0
	t.pops.append(official)
	WorldState.towns.append(t)
	var prof := ProfessionIncomeSystem.new()
	var total_before: float = st.treasury + official.savings
	prof.pay_officials()
	var expected_salary: float = 10.0 * ProfessionIncomeSystem.OFFICIAL_SALARY_PER_CAPITA_WEEKLY   # 120
	var total_after: float = st.treasury + official.savings
	var passed: bool = true
	var detail: String = ""
	if abs(official.savings - expected_salary) > 0.001:
		passed = false
		detail = "official savings wrong: %.4f (expect %.4f)" % [official.savings, expected_salary]
	elif abs(st.treasury - (1000.0 - expected_salary)) > 0.001:
		passed = false
		detail = "treasury wrong: %.4f (expect %.4f)" % [st.treasury, 1000.0 - expected_salary]
	elif abs(total_after - total_before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [total_before, total_after]
	else:
		detail = "official +%.1f, treasury -%.1f (880.0), conserved" % [expected_salary, expected_salary]
	_report("officials_paid_from_state_treasury", passed, detail)
	return passed

## Treasury (50) < total salary (120) → every payout scaled by 50/120;
## treasury drains to ~0; total credited == 50; conserved.
func test_officials_scale_down_on_thin_treasury() -> bool:
	WorldState.reset()
	var st := State.new("england", "England", 50.0, 0.0)
	WorldState.states.append(st)
	var t := Town.new("t1", "T1")
	t.state_id = "england"
	var official := Pop.new("p_off", "t1", "rich", "official", 10.0)
	official.savings = 0.0
	t.pops.append(official)
	WorldState.towns.append(t)
	var prof := ProfessionIncomeSystem.new()
	var total_before: float = st.treasury + official.savings
	prof.pay_officials()
	# total salary = 120, treasury 50 → scale 50/120 → official gains 50.
	var passed: bool = true
	var detail: String = ""
	if abs(official.savings - 50.0) > 0.001:
		passed = false
		detail = "official should get scaled 50.0: %.4f" % official.savings
	elif abs(st.treasury) > 0.001:
		passed = false
		detail = "treasury should drain to 0: %.4f" % st.treasury
	elif abs((st.treasury + official.savings) - total_before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [total_before, st.treasury + official.savings]
	else:
		detail = "salary 120, treasury 50 → scaled payout 50.0, treasury→0, conserved"
	_report("officials_scale_down_on_thin_treasury", passed, detail)
	return passed

## Broke state (treasury 0) pays its officials nothing.
func test_officials_nothing_when_treasury_zero() -> bool:
	WorldState.reset()
	var st := State.new("england", "England", 0.0, 0.0)
	WorldState.states.append(st)
	var t := Town.new("t1", "T1")
	t.state_id = "england"
	var official := Pop.new("p_off", "t1", "rich", "official", 10.0)
	official.savings = 0.0
	t.pops.append(official)
	WorldState.towns.append(t)
	var prof := ProfessionIncomeSystem.new()
	prof.pay_officials()
	var passed: bool = true
	var detail: String = ""
	if abs(official.savings) > 0.001:
		passed = false
		detail = "broke state should pay 0: official savings=%.4f" % official.savings
	elif abs(st.treasury) > 0.001:
		passed = false
		detail = "treasury should stay 0: %.4f" % st.treasury
	else:
		detail = "treasury 0 → no payout, officials rely on savings alone"
	_report("officials_nothing_when_treasury_zero", passed, detail)
	return passed

## Full-world 365-day sim with crew wages + officials' salary wired in.
## total_money conserved (|drift| < 1.0). Also reports sailor savings in the
## player's home port (Tortuga) and total state treasuries, for visibility.
func test_drift_zero_365days_full_world() -> bool:
	WorldState.build_world()
	var engine := SimulationEngine.new()
	var money_before: float = WorldState.total_money()
	engine.run_days(365)
	var money_after: float = WorldState.total_money()
	var drift: float = money_after - money_before
	var passed: bool = abs(drift) < 1.0
	# Visibility: sailor savings in Tortuga (player home port) + state treasuries.
	var tortuga: Town = WorldState.get_town("tortuga")
	var tortuga_sailor_sav: float = 0.0
	if tortuga != null:
		for p in tortuga.pops:
			if p.profession == "sailor":
				tortuga_sailor_sav = p.savings
				break
	var total_treasury: float = 0.0
	for st in WorldState.states:
		total_treasury += st.treasury
	var detail: String = "money=%.1f→%.1f drift=%.4f tortuga_sailor_savings=%.1f state_treasury_total=%.1f (need |drift|<1)" % [money_before, money_after, drift, tortuga_sailor_sav, total_treasury]
	_report("drift_zero_365days_full_world", passed, detail)
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
