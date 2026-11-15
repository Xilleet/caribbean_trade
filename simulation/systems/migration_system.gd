class_name MigrationSystem
extends RefCounted

## Stage B2b+B3: organic migration via ships.
##
## Weekly: for each town, compute migration pressure per profession.
## Pop wants to leave if: high unemployment + low wages + low satisfaction.
## Pop wants to go to: town with best wage_rate * satisfaction for their profession.
##
## Stage B3.1: profession-aware destination. Pop checks if destination has
## UNMET DEMAND for their profession (industries requiring it, with
## target_workers > available supply). If no town has unmet demand →
## fall back to satisfaction-based migration (any better town).
## This connects to C2/C8: if player builds a new smithy in a town,
## smiths from other towns will migrate there.
##
## Migration is NOT teleportation — Pops join the town's [param waiting_passengers]
## queue. Ships with [param passenger_capacity] pick them up when they dock.
##
## Conservation: Pop.count is NOT in [param WorldState.total_money], so
## drift=0 is preserved regardless of how many Pops move.

const MIGRATION_RATE: float = 0.02   # 2% of stressed population per week

## Weekly migration pressure computation. For each town, for each Pop:
## compute push factor (want to leave) + find best destination (pull).
## Add to town.waiting_passengers queue for ships to pick up.
func compute_migration(towns: Array) -> void:
	var recipes: Dictionary = WorldState.recipes
	for t in towns:
		_cap_waiting_queue(t)
		for p in t.pops:
			if p.count <= 0.0:
				continue
			# Push: unemployment + low wages + low satisfaction (per-Pop).
			var unemp: float = 1.0 - (p.employed_count / p.count) if p.count > 0.0 else 1.0
			var wage: float = float(t.wage_rate.get(p.profession, 1.0))
			var sat: float = p.satisfaction
			var push: float = unemp * (1.0 - wage / 2.0) * (1.0 - sat)
			var wanting: float = p.count * push * MIGRATION_RATE
			if wanting < 0.5:
				continue
			# Pull: find best destination with profession-aware logic.
			# 1. Prefer towns with UNMET DEMAND for this profession (shortage).
			# 2. If no town has unmet demand → fall back to wage * satisfaction.
			var best_demand_dest: String = ""
			var best_demand_score: float = 0.0
			var best_fallback_dest: String = ""
			var best_fallback_score: float = wage * sat   # only move if better
			for other in towns:
				if other.id == t.id:
					continue
				var other_wage: float = float(other.wage_rate.get(p.profession, 1.0))
				var other_score: float = other_wage * other.satisfaction
				# Check unmet demand: does this town have industries needing
				# this profession, with demand > available supply?
				if _has_unmet_demand(other, p.profession, recipes):
					if other_score > best_demand_score:
						best_demand_score = other_score
						best_demand_dest = other.id
				# Also track fallback (any town with better score).
				if other_score > best_fallback_score:
					best_fallback_score = other_score
					best_fallback_dest = other.id
			# Prefer destination with unmet demand; fall back if none found.
			var dest: String = best_demand_dest if best_demand_dest != "" else best_fallback_dest
			if dest != "":
				t.waiting_passengers.append({
					"profession": p.profession,
					"count": wanting,
					"destination": dest,
				})

## Check if town has UNMET DEMAND for a profession: industries requiring
## this profession have target_workers > available supply (shortage).
## Returns true if migration to this town would likely result in employment.
func _has_unmet_demand(town: Town, prof: String, recipes: Dictionary) -> bool:
	var demand: float = 0.0
	for ind in town.industries:
		var recipe: Dictionary = recipes.get(ind.recipe_id, {})
		if String(recipe.get("profession_required", "laborer")) == prof:
			demand += ind.target_workers
	if demand <= 0.0:
		return false   # no industries need this profession here
	var supply: float = town.get_available_workers(prof)
	return demand > supply

## Cap waiting queue to prevent infinite buildup. Keeps only the most recent
## entries per profession (passengers who waited longest give up and return
## to the population — they don't actually leave until a ship boards them).
func _cap_waiting_queue(t: Town) -> void:
	# Group by profession, keep last 5 entries each (most recent wanting).
	var by_prof: Dictionary = {}   # prof -> Array of entries
	var keep: Array = []
	for entry in t.waiting_passengers:
		var prof: String = String(entry["profession"])
		if not by_prof.has(prof):
			by_prof[prof] = []
		by_prof[prof].append(entry)
	for prof in by_prof.keys():
		var arr: Array = by_prof[prof]
		# Keep last 5 entries per profession.
		var start: int = max(0, arr.size() - 5)
		for i in range(start, arr.size()):
			keep.append(arr[i])
	t.waiting_passengers = keep
