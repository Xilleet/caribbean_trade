extends Node

## Stage 1 balance analysis. Runs a full-world 365-day sim and prints:
##   - per-profession aggregates (total count, total savings, avg satisfaction/SoL)
##   - per-state treasury (which states fund their officials, which are broke)
##   - Pops on mobility cooldown (did promotion/demotion fire at all?)
##   - drift
## Run with:
##   godot --headless --path <project> tests/sim_analysis.tscn

func _ready() -> void:
	WorldState.build_world()
	# Snapshot per-profession counts BEFORE, to see growth/shrink over the year.
	var count_before := _profession_counts()
	var sav_before := _profession_savings()
	var engine := SimulationEngine.new()
	engine.run_days(365)
	var count_after := _profession_counts()
	var sav_after := _profession_savings()
	var drift: float = WorldState.total_money() - 438700.0
	print("=== Stage 1 — 365-day sim analysis ===")
	print("drift = %.4f (build_world total_money = 438700.0)" % drift)
	print("")
	print("=== Per-profession (across all towns) ===")
	print("%-14s %10s %10s %12s %12s %8s" % ["profession", "count", "Δcount", "savings", "Δsavings", "avgSoL"])
	var profs := ["laborer", "sailor", "servant", "artisan", "smith", "merchant", "small_planter", "planter", "official", "financier"]
	for prof in profs:
		var c_after: float = float(count_after.get(prof, 0.0))
		var c_before: float = float(count_before.get(prof, 0.0))
		var s_after: float = float(sav_after.get(prof, 0.0))
		var s_before: float = float(sav_before.get(prof, 0.0))
		var sol: float = _avg_sol(prof)
		print("%-14s %10.0f %10.0f %12.0f %12.0f %8.3f" % [prof, c_after, c_after - c_before, s_after, s_after - s_before, sol])
	print("")
	print("=== Per-state treasury (officials paid from these) ===")
	for st in WorldState.states:
		var off_count: float = 0.0
		for t in WorldState.towns:
			if t.state_id == st.id:
				off_count += t.get_available_workers("official")
		print("%-10s treasury=%10.0f  officials_in_state=%.0f" % [st.id, st.treasury, off_count])
	print("")
	var on_cooldown: int = 0
	for t in WorldState.towns:
		for p in t.pops:
			if p.mobility_cooldown > 0:
				on_cooldown += 1
	print("Pops on mobility cooldown (a transition fired recently): %d" % on_cooldown)
	# Stage 4: total land rent collected in the FINAL week (weekly_rent is reset
	# each week in WeeklyTick, so this is the last week's rent flow — proves the
	# rent channel is active and shows its weekly magnitude; flows to planter
	# Pops). Puts the otherwise-unused weekly_rent field into diagnostics.
	var weekly_rent_total: float = 0.0
	for t in WorldState.towns:
		for ind in t.industries:
			weekly_rent_total += ind.weekly_rent
	print("Land rent collected (final week): %.0f → planter Pops (Stage 4)" % weekly_rent_total)
	print("=== end ===")
	get_tree().quit(0)

func _profession_counts() -> Dictionary:
	var d := {}
	for t in WorldState.towns:
		for p in t.pops:
			d[p.profession] = float(d.get(p.profession, 0.0)) + p.count
	return d

func _profession_savings() -> Dictionary:
	var d := {}
	for t in WorldState.towns:
		for p in t.pops:
			d[p.profession] = float(d.get(p.profession, 0.0)) + p.savings
	return d

func _avg_sol(prof: String) -> float:
	var sum: float = 0.0
	var n: float = 0.0
	for t in WorldState.towns:
		for p in t.pops:
			if p.profession == prof:
				sum += p.satisfaction * p.count
				n += p.count
	return sum / n if n > 0.0 else 0.0
