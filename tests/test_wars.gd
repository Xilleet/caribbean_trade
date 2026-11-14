extends Node

## Stage A3 tests for relations, reputation, wars, port access, tax scaling.
## Run directly (prints PASS/FAIL and quits with an exit code) OR via GUT:
##   godot --headless --path <project> tests/test_wars.tscn
##
## Covers:
##  - state-state relations spawn with historical ~1600 values
##  - player_rep initialised to 0 for all states + pirates
##  - trading in a state's port raises player_rep with that state (+0.5)
##  - tax scales with low player_rep (rep=-50 → tax × 1.5)
##  - low player_rep (< -50) blocks docking
##  - war triggers when relation drops below -80
##  - war blocks docking for ships flying the enemy flag
##  - peace resets relations to -20

func _ready() -> void:
	var ok := true
	ok = ok and test_relations_spawn()
	ok = ok and test_trade_raises_rep()
	ok = ok and test_tax_scales_with_rep()
	ok = ok and test_low_rep_blocks_docking()
	ok = ok and test_war_triggers_at_low_relation()
	ok = ok and test_war_blocks_enemy_flag()
	ok = ok and test_peace_resets_relations()
	ok = ok and test_pirate_attack_lowers_pirate_rep()
	print("\n=== %s ===" % ("ALL STAGE-A3 TESTS PASSED" if ok else "SOME STAGE-A3 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_relations_spawn() -> bool:
	WorldState.build_world()
	# Historical ~1600 bilateral relations.
	var sp_en: float = WorldState.get_relation("spain", "england")
	var sp_nl: float = WorldState.get_relation("spain", "netherlands")
	var sp_fr: float = WorldState.get_relation("spain", "france")
	var en_nl: float = WorldState.get_relation("england", "netherlands")
	# Pair-key symmetry: get_relation("a","b") == get_relation("b","a").
	var sym_ok: bool = WorldState.get_relation("england", "spain") == sp_en
	# player_rep starts at 0 for all states + pirates.
	var rep_zero: bool = true
	for s in WorldState.states:
		if abs(WorldState.get_player_rep(s.id)) > 0.001:
			rep_zero = false
	if abs(WorldState.get_player_rep("pirates")) > 0.001:
		rep_zero = false
	# 6 state-pair entries for 4 states.
	var pairs_ok: bool = WorldState.state_relations.size() == 6
	var passed: bool = sp_en == -20.0 and sp_nl == -40.0 and sp_fr == -10.0 \
		and en_nl == 10.0 and sym_ok and rep_zero and pairs_ok
	_report("relations_spawn", passed,
		"sp:en=%.0f sp:nl=%.0f sp:fr=%.0f en:nl=%.0f sym=%s rep_zero=%s pairs=%d" %
		[sp_en, sp_nl, sp_fr, en_nl, sym_ok, rep_zero, WorldState.state_relations.size()])
	return passed

func test_trade_raises_rep() -> bool:
	WorldState.build_world()
	var ship: Ship = WorldState.get_player_ship()
	ship.cargo.clear()
	ship.cargo_used = 0.0
	var company: Company = WorldState.get_company(ship.owner_id)
	company.money = 5000.0
	# Tortuga = france, not a pirate haven (haven_towns = ["tortuga"] in pirates.json,
	# so trading here also raises pirate rep).
	var town: Town = WorldState.get_town("tortuga")
	ship.current_town_id = "tortuga"
	var rep_fr_before: float = WorldState.get_player_rep("france")
	var rep_pirate_before: float = WorldState.get_player_rep("pirates")
	var trade := TradeSystem.new(MarketSystem.new())
	trade.manual_buy(ship, company, town, "sugar", 10.0)
	var rep_fr_after: float = WorldState.get_player_rep("france")
	var rep_pirate_after: float = WorldState.get_player_rep("pirates")
	# +0.5 with france, +1.0 with pirates (tortuga is a haven).
	var passed: bool = abs((rep_fr_after - rep_fr_before) - 0.5) < 0.001 \
		and abs((rep_pirate_after - rep_pirate_before) - 1.0) < 0.001
	_report("trade_raises_rep", passed,
		"france rep %.2f->%.2f (+0.5 expected), pirates %.2f->%.2f (+1.0 expected)" %
		[rep_fr_before, rep_fr_after, rep_pirate_before, rep_pirate_after])
	return passed

func test_tax_scales_with_rep() -> bool:
	WorldState.build_world()
	# Set player_rep with france (tortuga) to -50 → tax multiplier = 1.5.
	WorldState.player_rep["france"] = -50.0
	var ship: Ship = WorldState.get_player_ship()
	ship.cargo.clear()
	ship.cargo_used = 0.0
	var company: Company = WorldState.get_company(ship.owner_id)
	company.money = 5000.0
	var town: Town = WorldState.get_town("tortuga")
	ship.current_town_id = "tortuga"
	var state: State = WorldState.get_state("france")
	var treasury_before: float = state.treasury
	var trade := TradeSystem.new(MarketSystem.new())
	var res: Dictionary = trade.manual_buy(ship, company, town, "sugar", 10.0)
	var cost: float = float(res["cost"])
	var expected_tax: float = cost * 0.05 * 1.5   # france base 5% × 1.5 (rep=-50)
	var actual_tax: float = state.treasury - treasury_before
	# Allow ±0.5 for float rounding across tranched pricing.
	var passed: bool = abs(actual_tax - expected_tax) < 0.5
	_report("tax_scales_with_rep", passed,
		"rep=-50 cost=%.1f expected_tax=%.2f actual_tax=%.2f (×1.5 scaling)" %
		[cost, expected_tax, actual_tax])
	return passed

func test_low_rep_blocks_docking() -> bool:
	WorldState.build_world()
	# Make france hate the player (rep = -60, below -50 threshold).
	WorldState.player_rep["france"] = -60.0
	var ship: Ship = WorldState.get_player_ship()
	# Player ship is docked at Tortuga (france) initially — that's fine, existing
	# dock is allowed. Try to sail to another france port... wait, only tortuga is
	# france in our setup. Use a different approach: spawn a fresh sailing arrival
	# at Tortuga and check _can_dock returns false.
	# Easier: directly test _can_dock via the ShipsTick instance.
	ship.flag_state = "england"   # player already english
	ship.pos = Vector2(0, 0)
	ship.state = "sailing"
	ship.destination_id = "tortuga"
	ship.current_town_id = ""
	var town: Town = WorldState.get_town("tortuga")
	var st := ShipsTick.new(TradeSystem.new(MarketSystem.new()), MarketSystem.new())
	# Call _can_dock directly (it's a method, just invoke).
	var can_dock: bool = st._can_dock(ship, town)
	var passed: bool = not can_dock   # should be blocked
	# Now neutral rep should allow docking.
	WorldState.player_rep["france"] = 0.0
	var can_dock_neutral: bool = st._can_dock(ship, town)
	passed = passed and can_dock_neutral
	_report("low_rep_blocks_docking", passed,
		"rep=-60 can_dock=%s (expect false), rep=0 can_dock=%s (expect true)" %
		[can_dock, can_dock_neutral])
	return passed

func test_war_triggers_at_low_relation() -> bool:
	WorldState.build_world()
	# Force spain:england relation below threshold.
	WorldState.set_relation("spain", "england", -90.0)
	var wars_before: int = WorldState.active_wars.size()
	# Roll war declarations many times — at prob 0.3/week, after ~20 weeks the
	# chance of NOT declaring is (0.7)^20 ≈ 0.0008 — virtually certain.
	# Use a fresh WarSystem each iteration? No — same rng stream, just call roll_weekly.
	var ws := WarSystem.new(WorldState.war_rng)
	for _i in 30:
		if WorldState.at_war("spain", "england"):
			break
		# Only roll declarations (skip decay/incidents/peace to keep relation low).
		# Call the private method via reflection-free trick: replicate the loop here.
		# Simpler: just call _roll_war_declarations directly.
		ws._roll_war_declarations()
		# Decay would lift relation back toward 0; manually re-set it each iteration.
		WorldState.set_relation("spain", "england", -90.0)
	var at_war: bool = WorldState.at_war("spain", "england")
	var wars_after: int = WorldState.active_wars.size()
	var passed: bool = at_war and wars_after > wars_before
	_report("war_triggers_at_low_relation", passed,
		"spain:england=-90, after 30 weekly rolls at_war=%s wars=%d->%d" %
		[at_war, wars_before, wars_after])
	return passed

func test_war_blocks_enemy_flag() -> bool:
	WorldState.build_world()
	# Inject an active war between spain and england.
	var w := WarSystem.ActiveWar.new()
	w.state_a = "spain"
	w.state_b = "england"
	w.days_left = -1
	WorldState.active_wars.append(w)
	# Player ship flies england; try to dock at a spain port (santiago).
	var ship: Ship = WorldState.get_player_ship()
	ship.flag_state = "england"
	ship.pos = Vector2(0, 0)
	ship.state = "sailing"
	ship.destination_id = "santiago"
	ship.current_town_id = ""
	var town: Town = WorldState.get_town("santiago")
	var st := ShipsTick.new(TradeSystem.new(MarketSystem.new()), MarketSystem.new())
	var can_dock_enemy: bool = st._can_dock(ship, town)
	# Same ship at an england port (port_royal) should be allowed.
	var town_en: Town = WorldState.get_town("port_royal")
	var can_dock_friendly: bool = st._can_dock(ship, town_en)
	# Spain-flagged AI ship at spain port — allowed.
	var ai_ship := Ship.new("test_sp", "spain_company", "sloop", 18.0, 60.0, 8.0)
	ai_ship.flag_state = "spain"
	var can_dock_self: bool = st._can_dock(ai_ship, town)
	var passed: bool = not can_dock_enemy and can_dock_friendly and can_dock_self
	_report("war_blocks_enemy_flag", passed,
		"england-ship→spain-port=%s (expect false), →england-port=%s (expect true), spain-ship→spain-port=%s (expect true)" %
		[can_dock_enemy, can_dock_friendly, can_dock_self])
	return passed

func test_peace_resets_relations() -> bool:
	WorldState.build_world()
	# Inject an active war.
	var w := WarSystem.ActiveWar.new()
	w.state_a = "spain"
	w.state_b = "england"
	w.days_left = -1
	WorldState.active_wars.append(w)
	# Force relations to -90 (deep war).
	WorldState.set_relation("spain", "england", -90.0)
	var ws := WarSystem.new(WorldState.war_rng)
	# Roll peace many times — at prob 0.2/week, after ~30 rolls the chance of
	# no peace is (0.8)^30 ≈ 0.0024 — virtually certain to sign peace.
	var peace_signed: bool = false
	for _i in 40:
		if not WorldState.at_war("spain", "england"):
			peace_signed = true
			break
		ws._roll_peace()
	var relation_after: float = WorldState.get_relation("spain", "england")
	# On peace: relations reset to -20 (PEACE_RELATION constant).
	var passed: bool = peace_signed and abs(relation_after - (-20.0)) < 0.001
	_report("peace_resets_relations", passed,
		"peace_signed=%s relation_after=%.1f (expect -20.0)" %
		[peace_signed, relation_after])
	return passed

func test_pirate_attack_lowers_pirate_rep() -> bool:
	WorldState.build_world()
	# prob=1.0 so an attack definitely fires; player ship with cargo.
	WorldState.pirates_db["pirate_attack"]["prob_per_sailing_day"] = 1.0
	var ship: Ship = WorldState.get_player_ship()
	ship.cargo.clear()
	ship.cargo_used = 0.0
	ship.add_cargo("sugar", 20.0)
	ship.pos = WorldState.get_town("tortuga").coords
	ship.destination_id = "port_royal"
	ship.state = "sailing"
	ship.current_town_id = ""
	var rep_before: float = WorldState.get_player_rep("pirates")
	var engine := SimulationEngine.new()
	engine.run_days(1)
	var rep_after: float = WorldState.get_player_rep("pirates")
	# Should have dropped by ~2 (one pirate attack).
	var passed: bool = (rep_before - rep_after) >= 1.5   # allow slack
	_report("pirate_attack_lowers_pirate_rep", passed,
		"pirates rep %.2f -> %.2f (expect drop >= 1.5)" % [rep_before, rep_after])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
