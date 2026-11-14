class_name PriceMemory
extends RefCounted

## Per-company memory of market prices seen in ports it has docked at. The AI
## brain (AIBrain) and the player's planning view both read this instead of the
## live market, so neither is omniscient: a captain only knows the prices they
## last saw, and that knowledge goes stale as the world moves under them.
##
## Storage: town_id -> { good_id -> { "price": float, "day": int } }. A snapshot
## (taken on docking) overwrites that port's entries with today's real prices.
## Reads return the last-seen price regardless of age (the AI acts on possibly
## outdated info — that is the point); callers test [method fresh] to decide
## whether to trust or to scout. Entries are never silently dropped: the
## town/good grid is small (~15 towns x ~8 goods) and keeping stale rows lets
## the UI label them "stale" rather than "unknown".
##
## Determinism: no rng, no time-of-day reads — only caller-supplied day numbers
## and market values. Two runs at the same seed produce identical memory.

const MEMORY_DAYS: int = 10   # a port's prices are "fresh" for this many days

var _data: Dictionary = {}    # town_id -> { good_id -> {price, day} }

func clear() -> void:
	_data.clear()

## Record today's real prices for every good traded in [param town]. Called by
## ShipsTick when a ship docks (player or AI) and once per company at world
## build (the "starting rumour" — day-0 prices everywhere, so the player can
## plan a first route and the AI starts with common knowledge that ages out).
func snapshot(town: Town, day: int) -> void:
	if town == null or town.market == null:
		return
	var port: Dictionary = {}
	for gid in town.market.entries.keys():
		var e: Market.Entry = town.market.entries[gid]
		if e.stock < 0.01 and e.daily_demand < 0.01 and e.daily_supply < 0.01:
			continue   # match the UI's "skip dead goods" filter
		port[gid] = {"price": e.current_price, "day": day}
	_data[town.id] = port

## Directly set/overwrite the last-seen price for [param good_id] in [param
## town_id] as of [param day]. build_world seeds via snapshot; tests use this
## to inject controlled scenarios without running the simulation.
func set_estimate(town_id: String, good_id: String, price: float, day: int) -> void:
	if not _data.has(town_id):
		_data[town_id] = {}
	_data[town_id][good_id] = {"price": price, "day": day}

## Last-seen price for [param good_id] in [param town_id], or {} if never seen.
## Returns {"price": float, "days_ago": int} — days_ago is relative to
## [param now_day]. Stale (days_ago > MEMORY_DAYS) entries are still returned;
## callers decide via [method fresh] whether to trust them.
func estimate(town_id: String, good_id: String, now_day: int) -> Dictionary:
	if not _data.has(town_id):
		return {}
	var port: Dictionary = _data[town_id]
	if not port.has(good_id):
		return {}
	var rec: Dictionary = port[good_id]
	return {"price": float(rec["price"]), "days_ago": now_day - int(rec["day"])}

## Towns this company has any price record for. With [param fresh_only] true,
## only ports seen within MEMORY_DAYS of [param now_day] are returned.
func known_towns(now_day: int, fresh_only: bool = false) -> Array:
	var out: Array = []
	for tid in _data.keys():
		if fresh_only and not fresh(tid, now_day):
			continue
		out.append(tid)
	out.sort()   # deterministic order
	return out

## Is [param town_id]'s memory fresh (seen within MEMORY_DAYS of [param now_day])?
func fresh(town_id: String, now_day: int) -> bool:
	if not _data.has(town_id):
		return false
	var port: Dictionary = _data[town_id]
	for gid in port.keys():
		var rec: Dictionary = port[gid]
		if now_day - int(rec["day"]) <= MEMORY_DAYS:
			return true   # at least one good seen recently
	return false

## A port the company has never seen (or only stale data), for exploration.
func unknown_or_stale_towns(all_town_ids: Array, now_day: int) -> Array:
	var out: Array = []
	for tid in all_town_ids:
		if not fresh(tid, now_day):
			out.append(tid)
	out.sort()   # deterministic
	return out
