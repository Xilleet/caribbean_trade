extends Node

## Global signal bus. Systems emit here; the UI (Stage 3) will connect to
## refresh panels without ever reading economic state directly. The economic
## core itself does not depend on any signal being connected — emitting to
## zero listeners is free.

signal day_advanced(day: int)
signal week_advanced(week: int)
signal town_updated(town_id: String)
signal price_changed(town_id: String, good_id: String, new_price: float)
signal trade_completed(town_id: String, good_id: String, qty: float, price: float)
signal ship_docked(ship_id: String, town_id: String)
signal message(text: String)
# C4: emitted once at the END of step_day, AFTER a company's bankrupt flag is
# set (so listeners see the final state in the same frame). UI connects to
# this to show the game-over modal; the message signal above still carries the
# human-readable line for the event log. Free to emit with no listeners.
signal bankruptcy_declared(company_id: String)
