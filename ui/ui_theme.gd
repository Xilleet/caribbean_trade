class_name UITheme
extends RefCounted

## Shared UI helpers for the Stage UI-1 scene-based UI.
##
## The Stage 3/4 game_ui.gd builds every label/button in code with
## add_theme_font_override / add_theme_color_override calls. Now that the UI
## is split into several independent sub-scenes (hud, town_panel, event_log,
## game_ui itself + the dynamic panels left in game_ui), the font load and the
## label/button factories would otherwise be copy-pasted into each script.
## Centralising them here keeps the look identical and the diff small.
##
## Reads NO game state and mutates nothing — pure view helpers. The economic
## core is unaffected, so determinism and money conservation hold.

const FONT_PATH: String = "res://ui/fonts/DejaVuSansMono.ttf"

# Lazily loaded once per process; load() is cached by Godot so repeated calls
# are cheap, but a static var avoids even the dictionary lookup.
static var _font: Font = null

## Returns the bundled monospace font, with the same OS-font fallback the old
## game_ui.gd used, so a direct `godot --path .` run with no editor import still
## renders. The fallback path is the reason we cannot just set a Theme default
## font (a Theme cannot describe a SystemFont fallback) — so we keep the manual
## override path that already works.
static func load_font() -> Font:
	if _font != null:
		return _font
	var f = load(FONT_PATH)
	if f != null and f is Font:
		_font = f
		return _font
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"])
	_font = sf
	return _font

## Mirrors game_ui.gd::_mklabel — same font, size, colour, left alignment — so
## labels built dynamically (per-good trade rows, per-state diplomacy rows,
## route rows) look identical to the static labels now declared in .tscn.
static func make_label(parent: Control, text: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", load_font())
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	parent.add_child(l)
	return l

## Mirrors game_ui.gd::_mkbutton — same factory, so dynamic buttons match the
## static speed buttons in hud.tscn.
static func make_button(parent: Control, text: String, callable: Callable,
		w: float, h: float, fs: int, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", load_font())
	b.add_theme_font_size_override("font_size", fs)
	b.add_theme_color_override("font_color", color)
	b.custom_minimum_size = Vector2(w, h)
	b.pressed.connect(callable)
	parent.add_child(b)
	return b

## Mirrors game_ui.gd::_sep — the thin divider between sections.
static func make_separator() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 2)
	return s
