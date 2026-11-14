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
