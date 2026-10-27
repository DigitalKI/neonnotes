class_name TfidfIndex
extends RefCounted
## Body-word TF-IDF index over the vault — the semantic half of Area View.
##
## Pure and dependency-free: no autoload, no scene tree, no file I/O. Callers
## hand it note text and read vectors/neighbours back, so it unit-tests under
## `godot --script` exactly like RelationshipEngine/TagMatch. It is also the
## inverted index that makes relationship scoring scale past O(n^2): instead of
## scoring a note against every other note, `top_neighbors()` looks up the note's
## terms in the postings and scores only the notes sharing at least one term.
##
## Stored state (all incrementally maintainable):
##   _docs     path -> {term: raw count}
##   _postings term -> {path: raw count}   (the inverted index)
##   _df       term -> document frequency
## TF-IDF weights and L2-normalised vectors are computed on demand from `_df`,
## so adding/removing a note never leaves stale idf weights behind.

## Tokeniser: lowercases and splits on Unicode letters/digits/underscore
## (PCRE2 \p{L}\p{N}_), so accented Latin, Cyrillic and CJK words tokenise as
## words while punctuation and whitespace split. Returns {term: count}.
static var _token_re: RegEx

static func tokenize(text: String) -> Dictionary:
	if _token_re == null:
		_token_re = RegEx.create_from_string("[\\p{L}\\p{N}_]+")
	var out := {}
	for m in _token_re.search_all(String(text).to_lower()):
		var w := m.get_string()
		out[w] = int(out.get(w, 0)) + 1
	return out

var _docs := {}       # path -> {term: count}
var _postings := {}   # term -> {path: count}
var _df := {}         # term -> int (document frequency)

## Rebuild the whole index from {path: full text}. Use for the one-time
## bootstrap scan; per-note edits use `index_note()` / `remove_note()`.
func build(docs: Dictionary) -> void:
	_docs.clear()
	_postings.clear()
	_df.clear()
	for path in docs.keys():
		index_note(String(path), String(docs[path]))

## Add or replace one note's terms, maintaining postings + df. Cheap enough to
## run per note during an incremental scan; no full rebuild needed.
func index_note(path: String, text: String) -> void:
	remove_note(path)
	var counts := tokenize(text)
	if counts.is_empty():
		return
	_docs[path] = counts
	for term in counts.keys():
		if not _postings.has(term):
			_postings[term] = {}
		_postings[term][path] = counts[term]
		_df[term] = int(_df.get(term, 0)) + 1

## Drop one note's terms, decrementing document frequencies.
func remove_note(path: String) -> void:
	if not _docs.has(path):
		return
	for term in _docs[path].keys():
		if _postings.has(term):
			_postings[term].erase(path)
			if _postings[term].is_empty():
				_postings.erase(term)
		var df := int(_df.get(term, 0)) - 1
		if df <= 0:
			_df.erase(term)
		else:
			_df[term] = df
	_docs.erase(path)

func size() -> int:
	return _docs.size()

## Smoothed inverse document frequency: log((1+N)/(1+df)) + 1 (always positive).
func idf(term: String) -> float:
	var df := int(_df.get(term, 0))
	return log((1.0 + float(_docs.size())) / (1.0 + float(df))) + 1.0

## L2-normalised TF-IDF vector for one note: {term: weight}. Normalised so the
## cosine similarity between two vectors is simply their dot product.
func vector(path: String) -> Dictionary:
	var tf: Dictionary = _docs.get(path, {})
	var v := {}
	var norm := 0.0
	for term in tf.keys():
		var w := (1.0 + log(float(tf[term]))) * idf(term)
		v[term] = w
		norm += w * w
	if norm > 0.0:
		norm = sqrt(norm)
		for term in v.keys():
			v[term] = float(v[term]) / norm
	return v

## Cosine similarity between two notes' TF-IDF vectors, in [0, 1].
func cosine(a: String, b: String) -> float:
	return _dot(vector(a), vector(b))

## Top-k neighbours for `path` by TF-IDF cosine, via the inverted index:
## candidates are only the notes sharing at least one term, so this never scans
## the whole vault. Returns [{note, score}] sorted descending; k <= 0 = all.
func top_neighbors(path: String, k: int) -> Array:
	var q := vector(path)
	if q.is_empty():
		return []
	var candidates := {}
	for term in _docs.get(path, {}).keys():
		for c in _postings.get(term, {}).keys():
			if c != path:
				candidates[c] = true
	var scored: Array = []
	for c in candidates.keys():
		var s := _dot(q, vector(String(c)))
		if s > 0.0:
			scored.append({"note": String(c), "score": s})
	scored.sort_custom(func(a, b): return a["score"] > b["score"])
	if k > 0 and scored.size() > k:
		scored.resize(k)
	return scored

## Dot product of two normalised vectors (== cosine). Iterates the smaller side.
static func _dot(a: Dictionary, b: Dictionary) -> float:
	if a.size() > b.size():
		var t := a
		a = b
		b = t
	var sum := 0.0
	for term in a.keys():
		if b.has(term):
			sum += float(a[term]) * float(b[term])
	return sum
