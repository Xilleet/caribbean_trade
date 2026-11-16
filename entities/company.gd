class_name Company
extends RefCounted

## A trading company (the player or, later, an AI). Stage 1 only carries the
## wallet; buy/sell/trade-route logic arrives in Stage 2 and routes every
## transaction through [MarketSystem].

var id: String
var name: String
var money: float = 0.0
var is_ai: bool = false
var ship_ids: Array[String] = []
# snapshot of money at the start of the current simulated day. The UI
# shows `money - last_day_money` as today's net wallet delta so the player can
# see where funds went (upkeep drains are otherwise invisible). Snapshotted in
# SimulationEngine.step_day before any ticks run; not read by the economy.
var last_day_money: float = 0.0
# Stage A3.1: per-state week of the last bribe (state_id -> int week). Drives
# the 4-week bribe cooldown in the Diplomacy panel and main.bribe_state. Empty
# by default (no bribes yet); not read by the economy or any existing test.
var bribe_cooldowns: Dictionary = {}
# Price memory — last-seen per-port prices, used by AIBrain (AI
# ships) and the player's planning view. Initialised in WorldState.build_world
# with a day-0 snapshot of every port (the "starting rumour"); refreshed on
# dock by ShipsTick. Nullable only before build_world runs.
var memory: PriceMemory = null

# C4 (player bankruptcy + credit): the company-wide credit floor. Money can
# go negative down to -credit_limit (upkeep/trades still work in this range,
# layered UNDER C5's per-ship strand which fires first at -(upkeep×7)). The
# limit grows with fleet size so a bigger company has more headroom — and a
# further fall before game-over. Computed (not stored) so it auto-tracks
# ship_ids changes; no money moves here, drift=0.
const CREDIT_BASE: float = 2000.0
const CREDIT_PER_SHIP: float = 500.0

# C4: weekly interest rate on outstanding loans. 1%/week ≈ 4%/month — in the
# middle of the 3-5%/month range from the C4 design. Simple interest on
# principal (not compound) so the player can model the cost linearly.
# Conserved: debited from company.money, credited to state.treasury.
const LOAN_RATE_WEEKLY: float = 0.01

# C4: set when money drops below -credit_limit(). The SimulationEngine checks
# this at the start of step_day — a bankrupt PLAYER company freezes the sim
# (game-over state; no further ticks). AI companies just go idle (their ships
# strand via C5). Sticky: bankruptcy is terminal until a new game or an
# explicit reset (future: bankruptcy proceeding / takeover).
var bankrupt: bool = false

# C4: outstanding loans from state banks. state_id -> principal (accumulates:
# a second loan from the same state adds to the principal). Weekly interest
# accrues in SimulationEngine.step_week via accrue_loan_interest(). Repayment
# via repay_loan() reduces principal. Empty by default (no loans yet).
var loans: Dictionary = {}

func _init(p_id: String, p_name: String, p_money: float, p_is_ai: bool = false) -> void:
	id = p_id
	name = p_name
	money = p_money
	is_ai = p_is_ai

# C4: the credit floor — money can go negative down to -credit_limit() before
# the company goes bankrupt. Grows with fleet size (a 4-ship company has more
# headroom than a 1-ship sloop). Pure getter over ship_ids.size(), so it
# auto-tracks fleet changes without storing state; no money moves, drift=0.
func credit_limit() -> float:
	return CREDIT_BASE + CREDIT_PER_SHIP * float(ship_ids.size())

# C4: borrow from a state bank. Capped at the state's available treasury (a
# state with no cash can't lend). Moves money state.treasury -> company.money
# (conserved), records principal in loans[state_id]. Returns the actual
# amount lent (may be < requested if the state is thin). No-op if bankrupt.
func take_loan(amount: float, state_id: String) -> float:
	if amount <= 0.0 or bankrupt:
		return 0.0
	var state: State = WorldState.get_state(state_id)
	if state == null:
		return 0.0
	var lend: float = min(amount, state.treasury)
	if lend <= 0.0:
		return 0.0
	state.treasury -= lend
	money += lend
	loans[state_id] = float(loans.get(state_id, 0.0)) + lend
	return lend

# C4: repay part of a loan. Moves money company.money -> state.treasury
# (conserved), reduces principal. Capped at the outstanding principal AND at
# the company's available money (can't repay money you don't have — going
# further into debt to repay a loan makes no sense). Returns actual repaid.
func repay_loan(amount: float, state_id: String) -> float:
	if amount <= 0.0 or not loans.has(state_id):
		return 0.0
	var owed: float = float(loans[state_id])
	var pay: float = min(amount, owed)
	pay = min(pay, money)   # can't repay more than you have
	if pay <= 0.0:
		return 0.0
	var state: State = WorldState.get_state(state_id)
	if state == null:
		return 0.0
	money -= pay
	state.treasury += pay
	var remaining: float = owed - pay
	if remaining <= 0.0:
		loans.erase(state_id)
	else:
		loans[state_id] = remaining
	return pay

# C4: accrue weekly interest on all outstanding loans. Called once per week
# from SimulationEngine.step_week (after the town loop). Simple interest on
# principal: company.money -= principal×rate per state, state.treasury += same.
# Conserved. A bankrupt company still accrues interest (the debt grows) —
# bankruptcy is terminal, interest just records the ongoing cost. If a lender
# state vanished (defensive — shouldn't happen in Stage 1) the debt is voided.
func accrue_loan_interest() -> void:
	for state_id in loans.keys():
		var principal: float = float(loans[state_id])
		if principal <= 0.0:
			continue
		var state: State = WorldState.get_state(String(state_id))
		if state == null:
			loans.erase(state_id)
			continue
		var interest: float = principal * LOAN_RATE_WEEKLY
		money -= interest
		state.treasury += interest
