extends SceneTree
## Headless perf bench for the TfidfIndex derived-value caches (Area View).
## Builds a vault-sized synthetic index, then times the first (cold: vectors
## build and memoise) and second (warm: cache hits) whole-vault neighbour
## passes — the two costs `GraphView._layout_area_points()` pays per rebuild.
## Also exercises the common-term filter with words seeded into ~95% of the
## notes, the way function words behave in a real mixed-language vault.
##
##   godot --headless --path . --script scripts/dev/tfidf_bench.gd
##
## Dev-only and synthetic: no vault, no settings, safe to delete.

const TfidfIndexScript := preload("res://scripts/common/tfidf_index.gd")
const AreaEmbeddingScript := preload("res://scripts/common/area_embedding.gd")

const NOTES := 400
const SUBJECTS := 24
const TERMS_PER_NOTE := 90
const GLUE_IN_FRAC := 0.95   # fraction of notes carrying the glue words

func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261027  # fixed: runs stay comparable
	var docs := {}
	var glue_count := 0
	for i in NOTES:
		var words: Array = []
		if float(i) < GLUE_IN_FRAC * float(NOTES):
			words.append("gluea")
			words.append("glueb")
			glue_count += 1
		var subj := i % SUBJECTS
		for t in TERMS_PER_NOTE:
			words.append("s%dw%d" % [subj, rng.randi_range(0, 40)])
		if i % 7 == 0:  # a few cross-subject bridges so the graph is not disjoint
			words.append("s%dw3" % [(subj + 1) % SUBJECTS])
		docs["note%03d.md" % i] = " ".join(words)

	var idx = TfidfIndexScript.new()
	var t0 := Time.get_ticks_msec()
	idx.build(docs)
	var build_ms := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	var cold := idx.knn_graph(3)
	var cold_ms := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	var warm := idx.knn_graph(3)
	var warm_ms := Time.get_ticks_msec() - t0

	# The vector cache in isolation: a cold `vectors()` pass pays one build per
	# note; a warm one is pure cache hits. The pre-cache code rebuilt each
	# candidate's vector inside every top_neighbors() call, so it paid the
	# cold cost once per (note, candidate) pair instead of once per note.
	var idx2 = TfidfIndexScript.new()
	idx2.build(docs)
	t0 = Time.get_ticks_msec()
	idx2.vectors()
	var vectors_cold_ms := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	idx.vectors()
	var vectors_warm_ms := Time.get_ticks_msec() - t0

	# The Area View embedding over the same index (ADR-0016): the pass the
	# store's worker runs after the scan.
	t0 = Time.get_ticks_msec()
	var embed := AreaEmbeddingScript.layout(idx.knn_graph(3))
	var embed_ms := Time.get_ticks_msec() - t0

	# The cache paths (ADR-0016 Phase 3): a warm boot rebuilds the index from
	# persisted counts (no reads, no tokenisation) and a single-note edit
	# re-embeds warm-started from the previous positions.
	var counts_snap := {}
	for p in docs.keys():
		counts_snap[String(p)] = idx.term_counts(String(p))
	t0 = Time.get_ticks_msec()
	var idx_warm = TfidfIndexScript.new()
	idx_warm.build_counts(counts_snap)
	var build_counts_ms := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	AreaEmbeddingScript.layout(idx.knn_graph(3), AreaEmbeddingScript.ITERATIONS, embed)
	var warm_embed_ms := Time.get_ticks_msec() - t0

	# Cache exactness at bench scale: both passes must agree completely.
	var agree := true
	var edges := 0
	for p in cold.keys():
		if cold[p] != warm[p]:
			agree = false
		edges += (cold[p] as Array).size()

	var sample := idx.vector("note000.md")
	print("[tfidf bench] notes=%d build=%dms cold_knn=%dms warm_knn=%dms (%.1fx) "
		% [idx.size(), build_ms, cold_ms, warm_ms,
		float(cold_ms) / maxf(1.0, float(warm_ms))])
	print("[tfidf bench] vectors cold=%dms warm=%dms edges=%d cache_exact=%s glue_notes=%d glue_dropped=%s"
		% [vectors_cold_ms, vectors_warm_ms, edges, agree, glue_count,
		not sample.has("gluea")])
	print("[tfidf bench] embedding=%dms nodes=%d" % [embed_ms, embed.size()])
	print("[tfidf bench] cache load: build_counts=%dms warm_reembed=%dms"
		% [build_counts_ms, warm_embed_ms])
	quit(0)