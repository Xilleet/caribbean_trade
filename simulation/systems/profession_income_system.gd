class_name ProfessionIncomeSystem
extends RefCounted

## Weekly income for professions that have no industrial employer.
##
## Stage 1 (of the 6-stage profession-income plan): officials and sailors.
## Sailors are paid daily by ShipsTick (crew wages carved out of ship upkeep,
## credited to the home port's sailor Pop — see ShipsTick.CREW_WAGE_PER_DAY).
## This system handles the WEEKLY non-industrial incomes. Stage 1 here: state
## officials. Later stages add servants (rich-household expense), merchants
## (trade houses / intermediation), planters (land rent), financiers (credit).
##
## ## Officials
## A colonial official is paid a state salary from the treasury of the state
## that owns their town. [param State.treasury] accumulates customs tax
## (collected by [param TradeSystem._collect_customs] on every ship trade in
## the state's ports). Without this system the treasury only ever grows; paying
## officials is its first outflow — and the natural coupling to A4 (the player
## sets [param State.tax_rate] → treasury → officials paid).
##
## Money flow (per state, weekly):
##   state.treasury  ->  each official Pop's savings (in towns of that state)
## Both accounts are in [param WorldState.total_money], so drift = 0. If a
## state's treasury can't cover the full salary bill, every official's payout
## is scaled down by the same ratio (no money created) — a broke state pays
## its officials nothing, they deplete savings, SoL falls, and B4 demotes them
## (official → laborer, the dismissed-colonial-official transition). This is
## the intended feedback: trade through a state's ports funds its bureaucracy;
## a blockaded or trade-starved state loses its officials.

# Weekly salary per official (rich stratum — comparable to a skilled labourer's
# weekly wage, set so a state with steady customs covers its bureaucracy).
# Tuned via the 365-day sim; see WORKLOG Stage 1.
const OFFICIAL_SALARY_PER_CAPITA_WEEKLY: float = 12.0

## Pay every state's officials from that state's treasury. Runs once per week
## (called by [param WeeklyTick] on the first town of the week, like
## [param MigrationSystem.compute_migration]). Iterates [param WorldState.states],
## sums the official Pop count across each state's towns, computes the total
## salary, scales down if the treasury can't cover it, credits each town's
## official Pop, and debits the state treasury. No-op for states with no
## officials or no treasury.
func pay_officials() -> void:
	for st in WorldState.states:
		var state: State = st
		# Gather this state's towns and their official counts in one pass.
		var town_officials: Array = []   # [{town: Town, count: float}]
		var total_officials: float = 0.0
		for t in WorldState.towns:
			if t.state_id != state.id:
				continue
			var cnt: float = t.get_available_workers("official")
			if cnt > 0.0:
				town_officials.append({"town": t, "count": cnt})
				total_officials += cnt
		if total_officials <= 0.0:
			continue   # no officials in this state's towns
		var total_salary: float = total_officials * OFFICIAL_SALARY_PER_CAPITA_WEEKLY
		# Scale down if the treasury can't cover the full bill. A broke state
		# (treasury 0) pays nothing — its officials rely on savings alone.
		var scale: float = 1.0 if total_salary <= state.treasury else (state.treasury / total_salary if total_salary > 0.0 else 0.0)
		if scale <= 0.0:
			continue   # treasury empty — officials get nothing this week
		var paid: float = 0.0
		for entry in town_officials:
			var t: Town = entry["town"]
			var cnt: float = float(entry["count"])
			var payout: float = cnt * OFFICIAL_SALARY_PER_CAPITA_WEEKLY * scale
			t.add_to_pop("official", payout)
			paid += payout
		state.treasury -= paid
