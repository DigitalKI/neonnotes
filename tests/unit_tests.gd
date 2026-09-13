extends SceneTree

var failures := 0

func _init() -> void:
	_check_markdown_parser()
	_check_html_exporter()
	print("UNIT RESULT: %s (%d failures)" % ["FAIL" if failures > 0 else "OK", failures])
	quit(failures)

func _check_markdown_parser() -> void:
	var doc := MarkdownParser.parse("---\ntitle: \"Unit\"\ntheme: Toxic Terminal\n---\n\n# Heading\nfirst line\nsecond line\n\n```chart\ntype: line\nlabels: A, B\nvalues: 1, 2\n```")
	_check(doc["meta"].get("title") == "Unit", "front-matter title")
	_check(doc["meta"].get("theme") == "Toxic Terminal", "front-matter theme")
	_check(doc["blocks"].size() == 3, "parser block count")
	_check(doc["blocks"][1]["text"].contains("\n"), "paragraph newline preservation")
	_check(doc["blocks"][2]["chart_type"] == "line", "chart type")

func _check_html_exporter() -> void:
	var doc := MarkdownParser.parse("---\ntitle: HTML\n---\n\nfirst\nsecond")
	var html := HtmlExporter.to_html(doc)
	_check(html.begins_with("<!DOCTYPE html>"), "HTML document wrapper")
	_check(html.contains("<title>HTML</title>"), "HTML title")
	_check(html.contains("first<br>second"), "HTML paragraph newline")

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ✓ " + label)
	else:
		failures += 1
		print("  ✗ " + label)