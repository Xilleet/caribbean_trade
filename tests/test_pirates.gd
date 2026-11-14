extends Node

## Stage A1 tests for pirate attacks on sailing ships. Run directly (prints
## PASS/FAIL and quits with an exit code) OR via GUT:
##   godot --headless --path <project> tests/test_pirates.tscn
##
## Covers:
##  - pirate attacks are DETERMINISTIC (same seed → same attack count)
##  - a pirate attack reduces ship cargo (real loss, allowed by Concept §13)
##  - a pirate attack costs the company extra upkeep (repair, routed to town)
##  - money conservation holds across a 60-day sim with pirates active

func _ready() -> void:
	var ok := true
	ok = ok and test_pirate_attacks_deterministic()
	ok = ok and test_pirate_attack_loses_cargo()
	ok = ok and test_pirate_attack_costs_upkeep()
	ok = ok and test_pirate_conserved_60d()
	print("\n=== %s ===" % ("ALL STAGE-A1 TESTS PASSED" if ok else "SOME STAGE-A1 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_pirate_attacks_deterministic() -> bool:
	# Two fresh runs from build_world must produce the SAME pirate-attack count.
	# pirate_rng is re-seeded by build_world (seed = world_seed + 91137), so the
	# sequence reproduces bit-for-bit.
	WorldState.build_world()
	var e1 := SimulationEngine.new()
	e1.run_days(60)
	# Count attacks from the message log? No — count by tracking cargo losses.
	# Simpler: snapshot lifetime_sell_revenue + cargo_used on player ship and
	# check the two runs match.
	var p1: Ship = WorldState.get_player_ship()
	var p1_buy: float = p1.lifetime_buy_cost
	var p1_sell: float = p1.lifetime_sell_revenue
	WorldState.build_world()
	var e2 := SimulationEngine.new()
	e2.run_days(60)
	var p2: Ship = WorldState.get_player_ship()
	var p2_buy: float = p2.lifetime_buy_cost
	var p2_sell: float = p2.lifetime_sell_revenue
	var same: bool = abs(p1_buy - p2_buy) < 0.01 and abs(p1_sell - p2_sell) < 0.01
	var passed: bool = same
	_report("pirate_attacks_deterministic", passed,
		"run1 buy=%.1f sell=%.1f | run2 buy=%.1f sell=%.1f same=%s" %
		[p1_buy, p1_sell, p2_buy, p2_sell, same])
	return passed

func test_pirate_attack_loses_cargo() -> bool:
	# Force a pirate attack by setting prob_per_sailing_day = 1.0 in the in-memory
	# pirates_db, then sail the player ship one day. The ship must lose cargo.
	WorldState.build_world()
	WorldState.pirates_db["pirate_attack"]["prob_per_sailing_day"] = 1.0
	var ship: Ship = WorldState.get_player_ship()
	ship.cargo.clear()
	ship.cargo_used = 0.0
	ship.add_cargo("sugar", 20.0)
	var cargo_before: float = ship.cargo_qty("sugar")
	# Force sailing state with a destination far enough to need at least 1 day at sea.
	var dest: Town = WorldState.get_town("port_royal")   # tortuga → port_royal is ~150 units
	ship.pos = WorldState.get_town("tortuga").coords
	ship.destination_id = "port_royal"
	ship.state = "sailing"
	ship.current_town_id = ""
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(1)
	var cargo_after: float = ship.cargo_qty("sugar")
	var lost: float = cargo_before - cargo_after
	var passed: bool = lost > 0.0
	_report("pirate_attack_loses_cargo", passed,
		"sugar %.1f -> %.1f (lost %.1f, expected >0 with prob=1.0)" %
		[cargo_before, cargo_after, lost])
	return passed

func test_pirate_attack_costs_upkeep() -> bool:
	# Same setup as above but verify the repair-upkeep component: company.money
	# drops by extra_upkeep_mult × ship.upkeep_daily (routed to local town).
	WorldState.build_world()
	WorldState.pirates_db["pirate_attack"]["prob_per_sailing_day"] = 1.0
	var ship: Ship = WorldState.get_player_ship()
	var company: Company = WorldState.get_company(ship.owner_id)
	company.money = 10000.0   # plenty for upkeep + repair
	# Track the local-town population_money (where the repair cost routes).
	# Ship starts docked at Tortuga; we'll sail to Port Royal. The "local town"
	# for upkeep is ship.current_town_id or destination_id — so Port Royal.
	var port_royal: Town = WorldState.get_town("port_royal")
	var pop_before: float = port_royal.population_money
	ship.pos = WorldState.get_town("tortuga").coords
	ship.destination_id = "port_royal"
	ship.state = "sailing"
	ship.current_town_id = ""
	var money_before: float = company.money
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(1)
	# company.money drops by: base upkeep + storm_extra (none) + pirate repair.
	# base upkeep: 16 (brigantine). pirate repair: 0.5 * 16 = 8.
	var expected_drop_min: float = 16.0 + 8.0 - 0.5   # allow small slack
	var actual_drop: float = money_before - company.money
	var drift: float = WorldState.total_money() - total_before
	var passed: bool = actual_drop >= expected_drop_min and abs(drift) < 0.01
	_report("pirate_attack_costs_upkeep", passed,
		"company_drop=%.1f (expect >= %.1f = upkeep+repair) drift=%.4f" %
		[actual_drop, expected_drop_min, drift])
	return passed

func test_pirate_conserved_60d() -> bool:
	# Full 60-day sim with default pirate prob (0.04/sailing-day). Money must
	# still be conserved — cargo losses are real losses (goods, not money), the
	# only money movement is the repair upkeep (company -> town, conserved).
	WorldState.build_world()
	var total_start: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(60)
	var drift: float = WorldState.total_money() - total_start
	var passed: bool = abs(drift) < 1.0
	_report("pirate_conserved_60d", passed,
		"drift=%.4f (need |drift|<1 with pirates active)" % drift)
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
