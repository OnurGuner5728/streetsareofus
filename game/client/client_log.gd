class_name ClientLog
extends RefCounted
## Lifecycle events a web client reports to the page's logger (see
## html/head_include in export_presets.cfg), which tools/serve_web.py writes
## to build/client_logs.jsonl. Elsewhere they only go to stdout.


static func event(kind: String, message: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.soaLog && window.soaLog(%s, %s)" % [JSON.stringify(kind), JSON.stringify(message)], true)
	else:
		print("[client] %s: %s" % [kind, message])
