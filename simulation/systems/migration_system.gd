class_name MigrationSystem
extends RefCounted

## Stage B2b: organic migration via ships.
##
## Weekly: for each town, compute migration pressure per profession.
## Pop wants to leave if: high unemployment + low wages + low satisfaction.
## Pop wants to go to: town with best wage_rate * satisfaction for their profession.
##
## Migration is NOT teleportation — Pops join the town's [param waiting_passengers]
## queue. Ships with [param passenger_capacity] pick them up when they dock
## and their route/destination matches. Pops travel on the ship, then
## disembark at the destination town → Pop.count moves origin → ship → dest.
##
## Conservation: Pop.count is NOT in [param WorldState.total_money], so
## drift=0 is preserved regardless of how many Pops move.

const MIGRATION_RATE: float = 0.02   # 2% of stressed population per week

## Weekly migration pressure computation. For each town, for each Pop:
## compute push factor (want to leave) + find best destination (pull).
## Add to town.waiting_passengers queue for ships to pick up.
func compute_migration(towns: Array) -> void:
	for t in towns:
		# Don't clear waiting_passengers — they accumulate until a ship picks them up.
		# But cap the queue to prevent infinite buildup (last 20 entries per profession).
		_cap_waiting_queue(t)
		for p in t.pops:
			if p.count <= 0.0:
				continue
			# Push: unemployment + low wages + low satisfaction.
			var unemp: float = 1.0 - (p.employed_count / p.count) if p.count > 0.0 else 1.0
			var wage: float = float(t.wage_rate.get(p.profession, 1.0))
			var sat: float = t.satisfaction
			# push ∈ [0, 1]: high when unemployment is high, wages low, satisfaction low.
			var push: float = unemp * (1.0 - wage / 2.0) * (1.0 - sat)
			var wanting: float = p.count * push * MIGRATION_RATE
			if wanting < 0.5:
				continue   # too few to bother
			# Pull: find best destination (highest wage * satisfaction for this profession).
			var best_dest: String = ""
			var best_score: float = wage * sat   # only move if destination is better
			for other in towns:
				if other.id == t.id:
					continue
				var other_wage: float = float(other.wage_rate.get(p.profession, 1.0))
				var other_score: float = other_wage * other.satisfaction
				if other_score > best_score:
					best_score = other_score
					best_dest = other.id
			if best_dest != "":
				t.waiting_passengers.append({
					"profession": p.profession,
					"count": wanting,
					"destination": best_dest,
				})

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
