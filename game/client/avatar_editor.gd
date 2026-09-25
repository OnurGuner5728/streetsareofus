class_name AvatarEditor
extends VBoxContainer
## Every avatar option, in tabs (Beden, Yüz, Saç, Üst, Alt, Ayakkabı,
## Aksesuar), with a "Rastgele" button. Used by the main menu and by the
## in-game wardrobe; emits the sanitized avatar whenever anything changes.

signal changed(avatar: Dictionary)

const SLIDERS := [["height", "Boy"], ["weight", "Kilo"], ["muscle", "Kas"], ["shoulders", "Omuz"],
	["chest", "Göğüs"], ["hips", "Kalça"], ["legs", "Bacak boyu"], ["head", "Baş"]]
const LABELS := {
	"face": {"oval": "Oval", "round": "Yuvarlak", "square": "Köşeli", "long": "Uzun"},
	"eyes": {"brown": "Kahverengi", "dark": "Koyu", "hazel": "Ela", "green": "Yeşil", "blue": "Mavi", "grey": "Gri"},
	"brows": {"normal": "Normal", "thin": "İnce", "thick": "Kalın"},
	"beard": {"none": "Yok", "stubble": "Kirli sakal", "mustache": "Bıyık", "goatee": "Keçi sakalı", "short": "Kısa sakal", "full": "Gür sakal"},
	"hair": {"none": "Yok", "buzz": "Kazıtılmış", "short": "Kısa", "long": "Uzun", "bun": "Topuz", "curly": "Kıvırcık", "afro": "Afro"},
	"body_type": {"male": "Erkek", "female": "Kadın"},
	"top": {"tshirt": "Tişört", "longsleeve": "Uzun kollu", "shirt": "Gömlek", "polo": "Polo", "tank": "Atlet",
		"hoodie": "Kapüşonlu", "sweater": "Kazak", "jacket": "Ceket", "coat": "Mont", "dress": "Elbise"},
	"pattern": {"plain": "Düz", "stripes": "Çizgili", "two_tone": "İki renk"},
	"bottom": {"jeans": "Kot", "trousers": "Kumaş pantolon", "sweatpants": "Eşofman", "shorts": "Şort", "skirt": "Etek", "long_skirt": "Uzun etek"},
	"shoes": {"sneakers": "Spor ayakkabı", "boots": "Bot", "formal": "Klasik", "sandals": "Sandalet"},
	"headwear": {"none": "Yok", "cap": "Kep", "beanie": "Bere", "hat": "Fötr şapka", "headscarf": "Başörtüsü", "bandana": "Bandana"},
	"glasses": {"none": "Yok", "round": "Yuvarlak", "square": "Köşeli", "sun": "Güneş gözlüğü"},
	"bag": {"none": "Yok", "backpack": "Sırt çantası", "shoulder": "Omuz çantası", "tote": "Bez çanta"},
	"scarf": {"none": "Yok", "scarf": "Atkı"},
}

var avatar := {}
var _height_label: Label
var _tabs: TabContainer
var _rebuilding := false


func setup(initial: Dictionary) -> void:
	avatar = AvatarSpec.sanitize(initial)
	_rebuild()


func _rebuild() -> void:
	_rebuilding = true
	var keep_tab := _tabs.current_tab if _tabs else 0
	for child in get_children():
		child.queue_free()
	add_theme_constant_override("separation", 6)
	var top_row := HBoxContainer.new()
	add_child(top_row)
	var title := Label.new()
	title.text = "Görünüm"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(title)
	var dice := Button.new()
	dice.text = "Rastgele"
	dice.custom_minimum_size = Vector2(110, 36)
	dice.pressed.connect(_randomize)
	top_row.add_child(dice)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tabs)
	var body := _page("Beden")
	_choice(body, "Beden", "appearance", "body_type", AvatarSpec.BODY_TYPES, LABELS.body_type)
	for spec in SLIDERS:
		_slider(body, spec[0], spec[1])
	var note := Label.new()
	note.text = "Boy ve kilo yalnızca görünüştür; oyun içi çarpışma ve göz yüksekliği herkes için dar bir aralıkta tutulur."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.modulate = Color("8792a0")
	body.add_child(note)
	var face := _page("Yüz")
	var skins := AvatarSpec.SKINS.keys()
	var skin_labels := {}
	for i in skins.size():
		skin_labels[skins[i]] = "Ton %d" % (i + 1)
	_choice(face, "Ten", "appearance", "skin", skins, skin_labels)
	_choice(face, "Yüz şekli", "appearance", "face", AvatarSpec.FACES, LABELS.face)
	_choice(face, "Gözler", "appearance", "eyes", AvatarSpec.EYE_COLORS.keys(), LABELS.eyes)
	_choice(face, "Kaşlar", "appearance", "brows", AvatarSpec.BROWS, LABELS.brows)
	_choice(face, "Sakal", "appearance", "beard", AvatarSpec.BEARDS, LABELS.beard)
	var hair := _page("Saç")
	_choice(hair, "Saç", "appearance", "hair", AvatarSpec.HAIR_STYLES, LABELS.hair, "hair_color")
	var top := _page("Üst")
	_choice(top, "Üst", "clothing", "top", AvatarSpec.TOPS, LABELS.top, "top_color")
	_choice(top, "Desen", "clothing", "pattern", AvatarSpec.PATTERNS, LABELS.pattern, "top_color2")
	var bottom := _page("Alt")
	_choice(bottom, "Alt", "clothing", "bottom", AvatarSpec.BOTTOMS, LABELS.bottom, "bottom_color")
	var shoes := _page("Ayakkabı")
	_choice(shoes, "Ayakkabı", "clothing", "shoes", AvatarSpec.SHOES, LABELS.shoes, "shoes_color")
	var acc := _page("Aksesuar")
	_choice(acc, "Başlık", "accessories", "headwear", AvatarSpec.HEADWEAR, LABELS.headwear, "headwear_color")
	_choice(acc, "Gözlük", "accessories", "glasses", AvatarSpec.GLASSES, LABELS.glasses)
	_choice(acc, "Çanta", "accessories", "bag", AvatarSpec.BAGS, LABELS.bag, "bag_color")
	_choice(acc, "Atkı", "accessories", "scarf", AvatarSpec.SCARVES, LABELS.scarf, "scarf_color")
	_tabs.current_tab = clampi(keep_tab, 0, _tabs.get_tab_count() - 1)
	_update_height()
	_rebuilding = false


## A scrolling tab page; returns the box to fill.
func _page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	return box


func _slider(parent: Control, key: String, title: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(110, 0)
	row.add_child(label)
	if key == "height":
		_height_label = label
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(120, 30)
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = float(avatar.body[key])
	slider.value_changed.connect(func(v: float):
		avatar.body[key] = v
		_update_height()
		_emit())
	row.add_child(slider)


func _choice(parent: Control, title: String, group: String, key: String, ids: Array, labels: Dictionary, color_key := "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(90, 0)
	row.add_child(label)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.custom_minimum_size = Vector2(0, 36)
	for id in ids:
		opt.add_item(str(labels.get(id, id)))
	opt.select(maxi(0, ids.find(avatar[group][key])))
	opt.item_selected.connect(func(i: int):
		avatar[group][key] = ids[i]
		_emit())
	row.add_child(opt)
	if color_key != "":
		var picker := ColorPickerButton.new()
		picker.tooltip_text = title + " rengi"
		picker.color = Color(str(avatar[group][color_key]))
		picker.edit_alpha = false
		picker.custom_minimum_size = Vector2(64, 36)
		picker.color_changed.connect(func(c: Color):
			avatar[group][color_key] = "#" + c.to_html(false)
			_emit())
		row.add_child(picker)


func _update_height() -> void:
	if _height_label:
		_height_label.text = "Boy %d cm" % roundi(AvatarSpec.visual_height(avatar) * 100.0)


func _randomize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	avatar = AvatarSpec.random(rng)
	_rebuild()
	_emit()


func _emit() -> void:
	if _rebuilding:
		return
	avatar = AvatarSpec.sanitize(avatar)
	changed.emit(avatar)
