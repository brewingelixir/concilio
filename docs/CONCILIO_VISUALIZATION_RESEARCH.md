# Council Visualization Research

Research notes on how to visualize multi-agent councils in Concilio. Captured 2026-05-06 from a survey of multi-agent LLM frameworks (AutoGen, LangGraph, CrewAI), LLM observability tools (LangSmith, Langfuse, Weave, Helicone, AgentOps), multi-agent debate papers, and the Delphi method.

## Why this exists

The first iteration of `CouncilShowLive` shipped two diagrams (Flow swim-lanes + a collapsed Cytoscape "Topology"). Both made the same naive assumption: every member runs every round, full crossbar fan-in between rounds, all members feed chair. Real councils have per-round routing semantics (independent, peer-review, revision, debate, custom) that those diagrams ignored. This doc records the survey + a roadmap for honest visualization.

**Status (2026-05-07):** Rounds trellis (diagram A below) shipped, replacing the collapsed Topology — Rounds expresses the same connectivity _plus_ temporal order, so Topology was dropped as strictly subsumed. `CouncilShowLive` now exposes Flow (swim-lanes) and Rounds (trellis); both honor the inferred per-round type.

## Prior art

### LLM observability tools

LangSmith, Langfuse, Weave, Helicone, AgentOps, OpenAI Trace Viewer, AutoGen Studio all collapse to **nested span / waterfall timelines** (parent agent span → child tool span → LLM generation), plus a separate **execution graph** view. LangGraph Studio adds replay-from-checkpoint on the graph itself.

Almost no tool visualizes _disagreement_ between agents — they're built for single-agent tool-use traces, not deliberation.

### Multi-agent framework communication models

- **AutoGen GroupChat** — central `GroupChatManager` with pluggable speaker selection (`auto` / `manual` / `random` / `round_robin` / custom callable). Manager **broadcasts** the chosen speaker's message to all peers. ([AutoGen docs](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/design-patterns/group-chat.html))
- **LangGraph** — explicit DAG with conditional edges. Routing is **data on the edge**. ([tutorial](https://langchain-ai.github.io/langgraph/tutorials/multi_agent/multi-agent-collaboration/))
- **CrewAI** — role-based "crew" with `Process.sequential` / `Process.hierarchical`. Routing is implicit in the process type.

### Multi-agent debate research

Closest analogue to a council. The controlled-debate paper ([arXiv 2511.07784](https://arxiv.org/html/2511.07784v1)) and Tool-MAD ([arXiv 2601.04742](https://www.arxiv.org/pdf/2601.04742)) both use **per-round position heatmaps** (rows = agents, cols = rounds, cell = position/correctness). A-HMAD calls out heatmaps and "justification overlap" tracing as future work ([Springer](https://link.springer.com/article/10.1007/s44443-025-00353-3)).

### Delphi method (the human analogue)

Canonical viz is a **box plot per item per round** showing median + IQR contracting toward consensus. ([1000minds](https://www.1000minds.com/decision-making/delphi-method))

### Process notations

- BPMN swimlanes — _who owns what_
- UML sequence — _who messages whom in what order_
- Sankey — _quantity of flow_
- Gantt — _who ran when_

A council needs both swimlanes (structural) and sequence (temporal) ([ZenUML comparison](https://zenuml.com/blog/2024/05/19/2024/practical-examples-sequence-diagrams-replace-bpmn-business-process-modeling/)).

## Perspectives the user must understand

| #   | Perspective          | Why it matters for a council                                                                       |
| --- | -------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | Static structure     | Verify wiring before spending tokens                                                               |
| 2   | Temporal             | Did `peer_review` start before `independent_analysis` finished?                                    |
| 3   | **Information flow** | _Who saw what_ — the load-bearing question for any deliberation system; current diagrams ignore it |
| 4   | Decision flow        | Where chair drew its evidence; which member dominated synthesis                                    |
| 5   | Cost/economics       | One Opus member can cost 20× a Haiku peer                                                          |
| 6   | Disagreement         | The whole point of multi-model — show where members diverge                                        |
| 7   | Live progress        | Streaming feedback during a 30s+ run                                                               |
| 8   | Cross-run comparison | "Does adding member X change the answer?"                                                          |

## Diagram catalog

| #     | Name                                                                               | Answers                                                                                      | Archetype                                                                                                     | Static / Live          | Tools                          | Effort |
| ----- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------ | ------ |
| **A** | **Routing-aware Rounds trellis** (shipped 2026-05-07; replaced collapsed Topology) | "Per round, who reads whose output?"                                                         | DAG, member duplicated per round, edges colored by round type and generated from inferred `round.type`        | Static (template)      | Cytoscape + dagre (already in) | S      |
| **B** | **Sequence / Gantt Timeline**                                                      | "What ran when, how long, in parallel or serial?"                                            | Horizontal lanes per member, bars per round-step, dependency arrows                                           | Live                   | HEEx + SVG or Plotly           | M      |
| **C** | **Provenance Sankey**                                                              | "How much of the chair's final answer flowed from each member?" — uniquely visible only here | Sankey: members → chair, width = citation count or token contribution                                         | Live (post-run)        | Plotly or D3-sankey            | M      |
| **D** | **Position / Disagreement Heatmap**                                                | "Where did members converge or split, and when?" — Delphi/MAD canonical view                 | Grid: rows = members, cols = rounds, cell color = stance (agree/disagree/abstain) extracted by chair or judge | Live                   | HEEx + Tailwind grid           | S–M    |
| **E** | **Cost & Latency Treemap**                                                         | "Which agent is burning the budget?"                                                         | Treemap; area = tokens, color = $/ms                                                                          | Live                   | Plotly                         | S      |
| **F** | **Recursion Tree**                                                                 | "Where do sub-councils live in this template?" — currently invisible                         | Collapsible tree (hierarchical, like LangGraph nested traces)                                                 | Static                 | Cytoscape (compound nodes)     | S      |
| **G** | **Agreement-Convergence Chart**                                                    | "Did the panel actually converge?" — Delphi box-per-round                                    | Box plot or fan chart: x = round, y = stance score, band = IQR                                                | Live                   | Plotly                         | M      |
| **H** | **Live Trace Waterfall**                                                           | Industry-standard span view for debugging stalls/errors                                      | Nested waterfall (LangSmith/Langfuse-style)                                                                   | Live                   | HEEx + SVG                     | M      |
| **I** | **Run Diff**                                                                       | "What changed between run-A and run-B with member X swapped?"                                | Two-column heatmap or DAG overlay with delta highlighting                                                     | Static (post-run pair) | HEEx                           | M      |
| **J** | **Chair Attribution View**                                                         | "Which sentence in the final answer came from which member?"                                 | Final answer text with hover-highlighted source spans                                                         | Live (post-run)        | HEEx + tooltip                 | S–M    |

## Recommended priority (value × effort)

1. **A — Routing-aware Rounds trellis.** **Shipped 2026-05-07.** Fixes the original lie. Small effort once `round.type` is data (see §Routing semantics — currently inferred by heuristic, schema migration still pending). Highest user-value because every other diagram inherits its semantics.
2. **D — Position / Disagreement Heatmap.** Concilio's _raison d'être_ is multi-model deliberation; no other diagram makes consensus/dissent visible. Cheap (CSS grid). Mirrors MAD-paper convention directly.
3. **B — Sequence / Gantt Timeline.** Replaces the naive swim-lane Flow with something that survives parallel rounds, debate pairs, and async delays. Live progress doubles as "is it stuck?" debugging.
4. **C — Provenance Sankey.** The single most defensible answer to "why should I trust the chair's synthesis?" — and unique vs every observability tool out there.

Defer:

- E (Langfuse already covers cost)
- H (Langfuse covers waterfalls)
- F (only matters once recursion ships)
- G / I / J (need real run data first)

## Routing semantics — modeling per-round communication

Treat each round as a tagged record so diagrams render real edges, not assumed ones:

```
round := { id, type, members: [member_id], routing_spec }
type   ∈ { :independent | :peer_review | :revision | :debate | :custom }
```

Per-type `routing_spec`:

| Type           | Inputs to each member                                                                                                |
| -------------- | -------------------------------------------------------------------------------------------------------------------- |
| `:independent` | original prompt only — no peer inputs                                                                                |
| `:peer_review` | `{prompt, all_peers_outputs[round-1]}` — equivalent to AutoGen GroupChat broadcast after a `round_robin` pass        |
| `:revision`    | `{prompt, m.previous_output}` — self-loop only                                                                       |
| `:debate`      | `pairs: [{a, b}, …]`; each pair sees the other's previous output (maps to AutoGen two-agent chat × N pairs)          |
| `:custom`      | explicit `edges: [{from: member_id_or_:prompt, to: member_id}]` — fully general; matches LangGraph's edge-list model |

Chair is just a final round with `type: :synthesize`, `inputs: all_member_outputs_from_round_set`. Sub-councils are members whose `kind: :council` resolves recursively.

### Why this shape

It's the union of the three frameworks' models:

- LangGraph's explicit edges → `:custom`
- AutoGen's broadcast pattern → `:peer_review`
- CrewAI's sequential default → `:revision` / `:independent`

Storing routing as **data**, not template structure, means the Rounds trellis and Sankey diagrams can compile edges directly from `routing_spec` rather than assuming a fan-in crossbar. It also lets the heatmap label "what each member could see when forming this position" — the difference between an honest deliberation viz and a pretty graph.

### Implementation paths

Two ways to land routing data without breaking M0–M9 contracts:

1. **Schema-clean (preferred):** add `type` (string enum) + `routing_spec` (jsonb) to each round entry in `spec_json`. Bump `payload_version`. New rounds saved with explicit type; legacy rounds default to `:custom` with an inferred `routing_spec`.
2. **Heuristic transitional:** parse `round.module` (`IndependentAnalysis`, `PeerReview`, `Revision`, `Debate`, …) into a `type` at read time. Zero migration. Lossy on custom modules. Ship while planning the schema migration.

## Sources

- [AutoGen Group Chat](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/design-patterns/group-chat.html)
- [LangGraph multi-agent](https://langchain-ai.github.io/langgraph/tutorials/multi_agent/multi-agent-collaboration/)
- [CrewAI vs LangGraph vs AutoGen comparison](https://www.datacamp.com/tutorial/crewai-vs-langgraph-vs-autogen)
- [Langfuse observability](https://langfuse.com/docs/observability/overview)
- [LangSmith](https://www.langchain.com/langsmith/observability)
- [Multi-Agent Debate controlled study (heatmaps)](https://arxiv.org/html/2511.07784v1)
- [Tool-MAD](https://www.arxiv.org/pdf/2601.04742)
- [A-HMAD](https://link.springer.com/article/10.1007/s44443-025-00353-3)
- [Improving Factuality via MAD (Du et al.)](https://composable-models.github.io/llm_debate/)
- [Delphi method](https://www.1000minds.com/decision-making/delphi-method)
- [BPMN vs sequence diagrams (ZenUML)](https://zenuml.com/blog/2024/05/19/2024/practical-examples-sequence-diagrams-replace-bpmn-business-process-modeling/)
- [Sankey (Flourish)](https://flourish.studio/visualisations/sankey-charts/)
