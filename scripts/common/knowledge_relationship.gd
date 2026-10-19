class_name KnowledgeRelationship
extends RefCounted
## A typed relationship between two notes (ADR-0013). Provenance separates a
## fact (an explicit [[wiki-link]]) from computed candidates (inferred /
## suggested) and dismissed offers (rejected). Pure data — no GameManager, no
## file I/O, so it is unit-testable under `godot --script`.

var source: String = ""                  # vault-relative path
var target: String = ""                  # vault-relative path (RESOLVED)
var kind: String = ""                    # "wiki_link" now; signal kinds in Phase 2
var provenance: String = ""              # "explicit" | "inferred" | "suggested" | "rejected"
var score: float = 0.0
var evidence: Array[Dictionary] = []             # [{"kind","value","weight"}]
var source_locations: Array[Dictionary] = []      # reserved empty until Phase 4
