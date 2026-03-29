extends Control
## Main browser controller. Handles navigation, page fetching,
## HTML parsing, image loading, and rendering into a RichTextLabel.
##
## Flow for a page load:
##   navigate() → _fetch() → HTTPRequest → _on_request_completed()
##     → HtmlParser.to_bbcode() → render text immediately
##     → ImageLoader.fetch_all() → _on_image_ready() per image
##     → _inject_content_with_textures() rebuilds content with real textures
##     → _on_all_images_done() → final status update


const DEFAULT_HOME: String = ""
const MAX_REDIRECTS: int = 5

@onready var address_bar: LineEdit = $VBox/TopBar/AddressBar
@onready var back_btn: Button = $VBox/TopBar/BackBtn
@onready var forward_btn: Button = $VBox/TopBar/ForwardBtn
@onready var refresh_btn: Button = $VBox/TopBar/RefreshBtn
@onready var go_btn: Button = $VBox/TopBar/GoBtn
@onready var status_label: Label = $VBox/StatusBar/StatusLabel
@onready var loading_bar: ProgressBar = $VBox/StatusBar/LoadingBar
@onready var content: RichTextLabel = $VBox/ScrollContainer/Content
@onready var image_loader: ImageLoader = $ImageLoader
@onready var http: HTTPRequest = $HTTPRequest
@onready var bg: ColorRect = $bg

var history: BrowserHistory = BrowserHistory.new()
var _current_url: String = ""
var _redirect_count: int = 0
var _pending_bbcode: String = ""
# Textures keyed by resolved image URL — populated as images finish loading.
var _image_textures: Dictionary = {}


func _ready() -> void:
	http.request_completed.connect(_on_request_completed)
	content.meta_clicked.connect(_on_link_clicked)
	image_loader.image_ready.connect(_on_image_ready)
	image_loader.all_done.connect(_on_all_images_done)
	back_btn.pressed.connect(_on_back)
	forward_btn.pressed.connect(_on_forward)
	refresh_btn.pressed.connect(_on_refresh)
	go_btn.pressed.connect(_on_go)
	address_bar.text_submitted.connect(_on_address_submitted)

	if DEFAULT_HOME != "":
		navigate(DEFAULT_HOME)


# ── Navigation ────────────────────────────────────────────────────────────────


# Public entry point for all navigation. Normalises the URL first
# (adds https://, or converts bare words to a search query).
func navigate(url: String) -> void:
	url = _normalize_url(url)
	_redirect_count = 0
	_fetch(url)


func _fetch(url: String) -> void:
	# Clear state from the previous page so stale textures don't bleed through.
	_image_textures.clear()
	_pending_bbcode = ""

	_current_url = url
	address_bar.text = url
	_set_loading(true)
	status_label.text = "Connecting to %s…" % url

	# Spoof a real browser User-Agent — some servers reject requests without one.
	var headers: Array[String] = [
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
		"Accept: text/html,application/xhtml+xml,*/*;q=0.8",
		"Accept-Language: en-US,en;q=0.9",
	]

	http.cancel_request()
	var err: int = http.request(url, headers)
	if err != OK:
		_show_error("Request failed (error %d)" % err)


# ── HTTPRequest callback ──────────────────────────────────────────────────────


func _on_request_completed(
		result: int, code: int,
		headers: PackedStringArray, body: PackedByteArray) -> void:
	_set_loading(false)

	if result != HTTPRequest.RESULT_SUCCESS:
		_show_error("Network error (result %d)" % result)
		return

	# Follow HTTP redirects up to MAX_REDIRECTS times.
	if code in [301, 302, 303, 307, 308]:
		var location: String = _get_header(headers, "location")
		if location and _redirect_count < MAX_REDIRECTS:
			_redirect_count += 1
			_fetch(_resolve_url(location, _current_url))
			return
		else:
			_show_error("Too many redirects.")
			return

	if code < 200 or code >= 300:
		_show_error("HTTP %d" % code)
		return

	var html: String = body.get_string_from_utf8()

	# to_bbcode() calls inject_image_placeholders() internally — don't pre-process.
	_pending_bbcode = HtmlParser.to_bbcode(html)

	# Apply the page's background color before rendering text.
	var bg_color: String = HtmlParser.extract_body_bg(html)
	bg.color = Color(bg_color) if bg_color else Color(0.25, 0.25, 0.25)

	# Render text immediately — [[IMG:]] placeholders show as raw text until
	# their textures are ready and _inject_content_with_textures() runs.
	content.bbcode_enabled = true
	content.text = _pending_bbcode

	# Always push to history here, regardless of whether there are images.
	history.push(_current_url)
	_update_nav_buttons()

	var images: Array[Dictionary] = HtmlParser.extract_images(html)
	images.append_array(HtmlParser.extract_inline_svgs(html))

	if images.is_empty():
		_finish_page(html)
		return

	status_label.text = "Loading images…"
	var srcs: Array[String] = []
	for img_data in images:
		srcs.append(_resolve_url(img_data["src"], _current_url))
	image_loader.fetch_all(srcs, _current_url)


func _finish_page(html: String) -> void:
	var title: String = _extract_title(html)
	status_label.text = "✓  %s" % (title if title else _current_url)


# ── Link clicks ───────────────────────────────────────────────────────────────


func _on_link_clicked(meta: Variant) -> void:
	navigate(_resolve_url(str(meta), _current_url))


# ── Toolbar signal handlers ───────────────────────────────────────────────────


func _on_go() -> void:
	navigate(address_bar.text.strip_edges())


func _on_address_submitted(text: String) -> void:
	text = text.strip_edges()
	if _is_search_query(text):
		status_label.text = 'Searching for "%s"…' % text
	navigate(text)


func _on_back() -> void:
	if history.can_go_back():
		_fetch(history.go_back())
		_update_nav_buttons()


func _on_forward() -> void:
	if history.can_go_forward():
		_fetch(history.go_forward())
		_update_nav_buttons()


func _on_refresh() -> void:
	if _current_url:
		_fetch(_current_url)


# ── Image handling ────────────────────────────────────────────────────────────


func _on_image_ready(src: String, texture: ImageTexture) -> void:
	_image_textures[src] = texture
	_inject_content_with_textures()


func _on_all_images_done() -> void:
	_inject_content_with_textures()
	status_label.text = "✓  %s" % _current_url


# Rebuilds the RichTextLabel content, replacing every [[IMG:url]] placeholder
# with the decoded texture (if available) or a fallback label.
# Called once per image as they arrive so the page fills in progressively.
func _inject_content_with_textures() -> void:
	content.clear()
	content.bbcode_enabled = true

	var remaining: String = _pending_bbcode

	# Matches optional [url=...] wrapping around [[IMG:url]] placeholders
	# so we can make image links clickable.
	var img_regex: = RegEx.new()
	img_regex.compile("(\\[url=([^\\]]+)\\])?\\[\\[IMG:([^\\]]+)\\]\\](\\[/url\\])?")

	var last_end: int = 0
	for m in img_regex.search_all(remaining):
		var before: String = remaining.substr(last_end, m.get_start() - last_end)
		if before:
			content.append_text(before)

		var href: String = m.get_string(2)
		var src: String = _resolve_url(m.get_string(3), _current_url)

		if src in _image_textures:
			var tex: ImageTexture = _image_textures[src]
			var max_w: float = content.size.x if content.size.x > 0 else 600.0
			var w: float = minf(float(tex.get_width()), max_w)
			var h: float = float(tex.get_height()) * (w / float(tex.get_width()))
			if href:
				content.append_text("[url=%s]" % href)
				content.add_image(tex, int(w), int(h))
				content.append_text("[/url]")
			else:
				content.add_image(tex, int(w), int(h))
		else:
			if href:
				content.append_text("[url=%s]🔗[/url]" % href)

		last_end = m.get_end()

	var tail: String = remaining.substr(last_end)
	if tail:
		content.append_text(tail)


# ── Private helpers ───────────────────────────────────────────────────────────


# Returns true if the input looks like a search query rather than a URL.
# Bare words with no dots go to the search engine; "example.com" does not.
func _is_search_query(text: String) -> bool:
	if text.begins_with("http://") or text.begins_with("https://"):
		return false
	if "." in text and " " not in text:
		return false
	return true


# Ensures the URL has a scheme. Bare domains get https://, everything
# else is treated as a search query.
func _normalize_url(url: String) -> String:
	url = url.strip_edges()
	if url.begins_with("http://") or url.begins_with("https://"):
		return url
	if "." in url and " " not in url:
		return "https://" + url
	return "https://search.brave.com/search?q=" + url.uri_encode() + "&source=web"


# Resolves a potentially relative href against the current page URL.
# Absolute URLs are returned unchanged. Paths starting with "/" are
# resolved against the origin. Relative paths are resolved against
# the current directory.
func _resolve_url(href: String, base: String) -> String:
	if href.begins_with("http://") or href.begins_with("https://"):
		return href

	var regex: = RegEx.new()
	regex.compile("(https?://[^/]+)")
	var m: = regex.search(base)
	var origin: String = m.get_string(1) if m else ""

	if href.begins_with("/"):
		return origin + href

	var base_dir: String = base.substr(0, base.rfind("/") + 1)
	return base_dir + href


# Case-insensitive search for a specific response header value.
func _get_header(headers: PackedStringArray, key: String) -> String:
	for h in headers:
		if h.to_lower().begins_with(key.to_lower() + ":"):
			return h.substr(key.length() + 1).strip_edges()
	return ""


func _extract_title(html: String) -> String:
	var r: = RegEx.new()
	r.compile("(?i)<title[^>]*>(.*?)</title>")
	var m: = r.search(html)
	return m.get_string(1).strip_edges() if m else ""


func _set_loading(on: bool) -> void:
	loading_bar.visible = on
	refresh_btn.disabled = on


func _update_nav_buttons() -> void:
	back_btn.disabled = not history.can_go_back()
	forward_btn.disabled = not history.can_go_forward()


func _show_error(msg: String) -> void:
	content.bbcode_enabled = false
	content.text = "⚠ " + msg
	status_label.text = msg
	_set_loading(false)
