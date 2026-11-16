extends Control

## Stage UI-1 TownPanel — the "— Town —" section of the right column.
##
## Extracted from game_ui.gd::_build_layout. Owns the static title label and
## the read-only price-memory body; exposes a TradeSlot VBoxContainer where
## the parent game_ui.gd drops the dynamic per-good trade panel (built per
## click / dock, data-driven — kept in code, not in the scene).
##
## The body text itself is filled by game_ui.gd._render_town (it depends on
## the player's price memory + dock state, which lives on game_ui). TownPanel
## only holds the nodes; the data binding stays in game_ui to keep this scene
## a pure view. Reads no game state directly.

@onready var title_label: Label = %TownTitle
@onready var body_label: Label = %TownBody
@onready var trade_slot: VBoxContainer = %TradeSlot

func _ready() -> void:
	var f := UITheme.load_font()
	title_label.add_theme_font_override("font", f)
	title_label.add_theme_font_size_override("font_size", 15)
	title_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	body_label.add_theme_font_override("font", f)
	body_label.add_theme_font_size_override("font_size", 13)
	body_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	body_label.custom_minimum_size = Vector2(0.0, 150.0)
	trade_slot.add_theme_constant_override("separation", 2)
