class_name TfidfIndex
extends RefCounted
## Body-word TF-IDF index over the vault — the semantic half of Area View.
##
## Pure and dependency-free: no autoload, no scene tree, no file I/O. Callers
## hand it note text and read vectors/neighbours back, so it unit-tests under
## `godot --script` exactly like RelationshipEngine/TagMatch. It is also the
## inverted index that makes relationship scoring scale past O(n^2): instead of
## scoring a note against every other note, `top_neighbors()` looks up the
## note's terms in the postings and scores only the notes sharing at least one
## term.
##
## Stored state (all incrementally maintainable):
##   _docs     path -> {term: raw count}
##   _postings term -> {path: raw count}   (the inverted index)
##   _df       term -> document frequency
## TF-IDF weights and L2-normalised vectors are derived on demand and memoised
## (`_idf_cache`, `_vector_cache`). Every mutation clears both caches, so a
## cache hit is always exact: adding, removing or editing a note can never
## leave a stale idf weight or vector behind (the vector depends on global
## document frequencies, so it is a property of the whole corpus, not of the
## note alone). A term appearing in nearly every note carries no subject
## signal and is dropped from vectors entirely (COMMON_TERM_FRAC) — the
## stopword list is English-only, so this document-frequency filter is what
## keeps any other language's function words from gluing the whole vault into
## one giant similarity island. The Area View layout consumes whole-vault
## snapshots through `vectors()` / `knn_graph()` instead of paying the
## per-note vector rebuild N times over.

## Tokeniser: lowercases and splits on Unicode letters/digits/underscore
## (PCRE2 \p{L}\p{N}_), so accented Latin, Cyrillic and CJK words tokenise as
## words while punctuation and whitespace split. Returns {term: count}.
static var _token_re: RegEx

## Common English function words: too generic to carry subject meaning, so they
## are dropped rather than relying on IDF alone (which a small corpus cannot
## fully suppress). Non-English words pass through for now.
const _STOPWORDS := {
	"the": true, "and": true, "a": true, "an": true, "of": true, "to": true,
	"in": true, "for": true, "with": true, "on": true, "at": true, "by": true,
	"is": true, "are": true, "was": true, "were": true, "be": true, "been": true,
	"this": true, "that": true, "these": true, "those": true, "it": true,
	"from": true, "into": true, "over": true, "under": true, "or": true,
	"as": true, "not": true, "your": true, "you": true, "has": true, "have": true,
	"will": true, "can": true, "its": true, "our": true, "but": true, "if": true,
}

## A term appearing in at least this fraction of the notes is a universal
## connector, not a subject word: it is dropped from vectors, so two notes
## sharing nothing else score zero against each other. Chosen over stopword
## lists per language because it needs no language knowledge — in a
## mixed-language vault the function words of *each* language are the glue
## that merges everything into one island, and IDF smoothing (`+ 1`) keeps
## them weighted even at df = N.
const COMMON_TERM_FRAC := 0.85
## Below this note count "appears in nearly every note" is meaningless (in a
## two-note vault every shared word is in 100% of the notes), so the filter
## stays off and small vaults keep connecting on any shared word.
const COMMON_TERM_MIN_DOCS := 8

static func tokenize(text: String) -> Dictionary:
	if _token_re == null:
		_token_re = RegEx.create_from_string("[\\p{L}\\p{N}_]+")
	var out := {}
	for m in _token_re.search_all(String(text).to_lower()):
		var w := m.get_string()
		if _STOPWORDS.has(w):
			continue
		out[w] = int(out.get(w, 0)) + 1
	return out

var _docs := {}       # path -> {term: count}
var _postings := {}   # term -> {path: count}
var _df := {}         # term -> int (document frequency)
## Derived-value caches, exact because `_clear_derived()` runs on every
## mutation; values rebuild lazily on the next read.
var _idf_cache := {}    # term -> idf weight
var _vector_cache := {} # path -> L2-normalised {term: weight}

## Rebuild the whole index from {path: full text}. Use for the one-time
## bootstrap scan; per-note edits use `index_note()` / `remove_note()`.
func build(docs: Dictionary) -> void:
	_docs.clear()
	_postings.clear()
	_df.clear()
	_clear_derived()
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
	_clear_derived()

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
	_clear_derived()

## Derived caches are pure functions of the stored counts above, so any
## mutation invalidates them wholesale. Clearing is cheap and the values
## rebuild lazily on the next read, so an incremental edit only pays for the
## vectors actually requested afterwards — not for a per-note `log()` per term
## per candidate, which is what made the first Area View layout crawl.
func _clear_derived() -> void:
	_idf_cache.clear()
	_vector_cache.clear()

func size() -> int:
	return _docs.size()

## Smoothed inverse document frequency: log((1+N)/(1+df)) + 1 (always positive).
## Memoised; the cache is exact because mutations clear it.
func idf(term: String) -> float:
	if _idf_cache.has(term):
		return _idf_cache[term]
	var df := int(_df.get(term, 0))
	var v := log((1.0 + float(_docs.size())) / (1.0 + float(df))) + 1.0
	_idf_cache[term] = v
	return v

## True when `term` appears in so many notes that it cannot discriminate
## between subjects. Only active once the corpus is big enough for "nearly
## every note" to carry information.
func _is_common(term: String) -> bool:
	var n := _docs.size()
	if n < COMMON_TERM_MIN_DOCS:
		return false
	return float(int(_df.get(term, 0))) > float(n) * COMMON_TERM_FRAC

## L2-normalised TF-IDF vector for one note: {term: weight}. Normalised so the
## cosine similarity between two vectors is simply their dot product. Memoised;
## the returned dictionary is shared with the cache — callers must not mutate
## it. Common terms are skipped, so a pair sharing only universal words scores
## zero and a note made entirely of them has an empty (isolated) vector.
func vector(path: String) -> Dictionary:
	if _vector_cache.has(path):
		return _vector_cache[path]
	var tf: Dictionary = _docs.get(path, {})
	var v := {}
	var norm := 0.0
	for term in tf.keys():
		if _is_common(term):
			continue
		var w := (1.0 + log(float(tf[term]))) * idf(term)
		v[term] = w
		norm += w * w
	if norm > 0.0:
		norm = sqrt(norm)
		for term in v.keys():
			v[term] = float(v[term]) / norm
	_vector_cache[path] = v
	return v

## Every note's vector at once — {path: {term: weight}} — sharing the per-note
## cache, so the Area View embedding gets one build pass instead of N. The
## dictionaries are shared with the cache; callers must not mutate them.
func vectors() -> Dictionary:
	var out := {}
	for path in _docs.keys():
		out[String(path)] = vector(String(path))
	return out

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
		if _is_common(term):
			continue  # common terms are absent from every vector, so they
			# cannot lift any candidate above zero — walking their (huge)
			# postings would drag the whole vault in as candidates.
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

## Top-k neighbour graph for the whole vault: {path: [{note, score}]}. The
## same scoring as `top_neighbors()` over every note; with the vector cache
## warm this is one dot-product pass instead of a vector rebuild per candidate.
func knn_graph(k: int) -> Dictionary:
	var out := {}
	for path in _docs.keys():
		out[String(path)] = top_neighbors(String(path), k)
	return out

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