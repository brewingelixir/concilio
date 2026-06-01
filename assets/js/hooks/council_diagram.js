// Cytoscape-powered council flow diagram.
//
// LV passes the normalized diagram via a JSON-encoded `data-spec` attribute on
// a div tagged `phx-hook="CouncilDiagram"` + `phx-update="ignore"`. The hook
// owns the inner DOM; LV only diffs the data attribute.
//
// Spec shape (JSON):
//   {
//     "members": [{"id","provider","model","module","system_prompt"}, ...],
//     "rounds":  [{"name","module"}, ...],
//     "chair":   {"id","provider","model","module","system_prompt"} | null
//   }

import cytoscape from "cytoscape"
import dagre from "cytoscape-dagre"
import nodeHtmlLabel from "cytoscape-node-html-label"

cytoscape.use(dagre)
nodeHtmlLabel(cytoscape)

const MEMBER_W = 200
const MEMBER_H = 70
const CHAIR_W = 200
const CHAIR_H = 70

function escapeHtml(s) {
  if (s == null) return ""
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

const ROUND_TYPE_BADGE = {
  peer_review: "badge-warning",
  revision: "badge-secondary",
  debate: "badge-error",
  independent: "badge-info",
  synthesize: "badge-primary",
  custom: "badge-ghost",
}

function memberRoundCardHtml(data) {
  const { label, provider, model, roundIdx, roundType, roundName } = data
  const typeBadge = ROUND_TYPE_BADGE[roundType] || "badge-ghost"
  const typeLabel = roundType || "custom"
  const subtitle =
    roundName && roundName !== typeLabel
      ? `R${roundIdx} · ${escapeHtml(roundName)}`
      : `R${roundIdx}`
  return `
    <div class="card bg-base-200 border border-base-300 shadow-sm"
         style="width:${MEMBER_W}px; height:${MEMBER_H + 18}px;">
      <div class="card-body p-2 gap-1 justify-center">
        <div class="flex items-center justify-between gap-2">
          <span class="font-mono text-xs font-semibold truncate">${escapeHtml(label)}</span>
          <span class="badge badge-ghost badge-xs">${escapeHtml(subtitle)}</span>
        </div>
        <div class="flex flex-wrap gap-1">
          ${provider ? `<span class="badge badge-outline badge-xs">${escapeHtml(provider)}</span>` : ""}
          ${model ? `<span class="badge badge-primary badge-xs font-mono">${escapeHtml(model)}</span>` : ""}
          <span class="badge ${typeBadge} badge-xs">${escapeHtml(typeLabel)}</span>
        </div>
      </div>
    </div>
  `
}

function inputNodeHtml() {
  return `
    <div class="card bg-base-100 border border-dashed border-base-content/40 shadow-sm"
         style="width:140px; height:40px;">
      <div class="card-body p-2 justify-center items-center">
        <span class="font-mono text-xs font-semibold text-base-content/70">input</span>
      </div>
    </div>
  `
}

function chairCardHtml(data) {
  const { label, provider, model } = data
  return `
    <div class="card bg-primary/10 border border-primary/40 shadow-sm"
         style="width:${CHAIR_W}px; height:${CHAIR_H}px;">
      <div class="card-body p-2 gap-1 justify-center">
        <div class="flex items-center justify-between gap-2">
          <span class="font-mono text-xs font-semibold truncate">${escapeHtml(label)}</span>
          <span class="badge badge-primary badge-xs">chair</span>
        </div>
        <div class="flex flex-wrap gap-1">
          ${provider ? `<span class="badge badge-outline badge-xs">${escapeHtml(provider)}</span>` : ""}
          ${model ? `<span class="badge badge-primary badge-xs font-mono">${escapeHtml(model)}</span>` : ""}
        </div>
      </div>
    </div>
  `
}

// Round-trellis layout: each member appears once per round (row). Edges from
// round k-1 to round k follow round-k's type (peer_review/debate/custom →
// crossbar, revision → self-only, independent → none from peers, only input).
// Round 1 always reads `input` directly. Chair reads every member from the
// final round (synthesize).
function specToElementsRounds(spec) {
  const nodes = []
  const edges = []
  const members = spec.members || []
  const rounds = spec.rounds || []
  const chair = spec.chair
  const N = members.length

  const inputId = "input:start"
  nodes.push({ data: { id: inputId, label: "input", kind: "input" } })

  const roundNodeId = (k, mi) => `r${k}:m${mi}`

  rounds.forEach((round, idx) => {
    const k = idx + 1
    members.forEach((m, mi) => {
      nodes.push({
        data: {
          id: roundNodeId(k, mi),
          label: m.id || `member_${mi + 1}`,
          provider: m.provider || "",
          model: m.model || "",
          roundIdx: k,
          roundName: round.name || "",
          roundType: round.type || "custom",
          kind: "member_round",
        },
      })
    })

    if (idx === 0) {
      // Round 1: every member reads original input.
      members.forEach((_m, mi) => {
        edges.push({
          data: {
            id: `e:${inputId}->${roundNodeId(k, mi)}`,
            source: inputId,
            target: roundNodeId(k, mi),
            roundType: round.type || "custom",
            isInput: "true",
          },
        })
      })
      return
    }

    if (round.type === "independent") {
      // No peer reads — members only see input.
      members.forEach((_m, mi) => {
        edges.push({
          data: {
            id: `e:${inputId}->${roundNodeId(k, mi)}`,
            source: inputId,
            target: roundNodeId(k, mi),
            roundType: "independent",
            isInput: "true",
          },
        })
      })
      return
    }

    if (round.type === "revision") {
      // Each member reads only its own previous-round output.
      members.forEach((_m, mi) => {
        const src = roundNodeId(k - 1, mi)
        const tgt = roundNodeId(k, mi)
        edges.push({
          data: {
            id: `e:${src}->${tgt}`,
            source: src,
            target: tgt,
            roundType: "revision",
          },
        })
      })
      return
    }

    // peer_review / debate / custom → full crossbar (incl. self).
    for (let s = 0; s < N; s++) {
      for (let d = 0; d < N; d++) {
        const src = roundNodeId(k - 1, s)
        const tgt = roundNodeId(k, d)
        edges.push({
          data: {
            id: `e:${src}->${tgt}`,
            source: src,
            target: tgt,
            roundType: round.type || "custom",
          },
        })
      }
    }
  })

  // Degenerate: no rounds — render members in a single virtual row from input.
  if (rounds.length === 0 && N > 0) {
    members.forEach((m, mi) => {
      nodes.push({
        data: {
          id: roundNodeId(1, mi),
          label: m.id || `member_${mi + 1}`,
          provider: m.provider || "",
          model: m.model || "",
          roundIdx: 1,
          roundName: "(no rounds)",
          roundType: "custom",
          kind: "member_round",
        },
      })
      edges.push({
        data: {
          id: `e:${inputId}->${roundNodeId(1, mi)}`,
          source: inputId,
          target: roundNodeId(1, mi),
          roundType: "custom",
          isInput: "true",
        },
      })
    })
  }

  // Chair: reads every member of the final round (or input if no members).
  if (chair) {
    const cid = "chair:end"
    nodes.push({
      data: {
        id: cid,
        label: chair.id || "chair",
        provider: chair.provider || "",
        model: chair.model || "",
        kind: "chair",
      },
    })
    const finalK = Math.max(rounds.length, rounds.length === 0 && N > 0 ? 1 : 0)
    if (finalK > 0) {
      members.forEach((_m, mi) => {
        const src = roundNodeId(finalK, mi)
        edges.push({
          data: {
            id: `e:${src}->${cid}`,
            source: src,
            target: cid,
            roundType: "synthesize",
          },
        })
      })
    } else {
      edges.push({
        data: {
          id: `e:${inputId}->${cid}`,
          source: inputId,
          target: cid,
          roundType: "synthesize",
          isInput: "true",
        },
      })
    }
  }

  return [...nodes, ...edges]
}

// Read DaisyUI/Tailwind CSS variables off the document root so the diagram
// follows the active theme. Falls back to sensible neutrals if missing.
function themeColors() {
  const cs = getComputedStyle(document.documentElement)
  const v = (name, fallback) => cs.getPropertyValue(name).trim() || fallback
  return {
    base100: v("--color-base-100", "#ffffff"),
    base200: v("--color-base-200", "#f3f4f6"),
    base300: v("--color-base-300", "#e5e7eb"),
    baseContent: v("--color-base-content", "#1f2937"),
    primary: v("--color-primary", "#570df8"),
    primaryContent: v("--color-primary-content", "#ffffff"),
    secondary: v("--color-secondary", "#9333ea"),
    warning: v("--color-warning", "#f59e0b"),
    error: v("--color-error", "#ef4444"),
  }
}

function buildStyle() {
  const t = themeColors()
  return [
    {
      // Node is the layout footprint for the HTML overlay; keep it sized
      // exactly to the card so dagre doesn't overlap them, but fully
      // transparent so only the HTML shows.
      selector: 'node[kind = "member_round"]',
      style: {
        "background-opacity": 0,
        "border-width": 0,
        label: "",
        width: MEMBER_W,
        height: MEMBER_H + 18,
        shape: "round-rectangle",
      },
    },
    {
      selector: 'node[kind = "input"]',
      style: {
        "background-opacity": 0,
        "border-width": 0,
        label: "",
        width: 140,
        height: 40,
        shape: "round-rectangle",
      },
    },
    {
      selector: 'node[kind = "chair"]',
      style: {
        "background-opacity": 0,
        "border-width": 0,
        label: "",
        width: CHAIR_W,
        height: CHAIR_H,
        shape: "round-rectangle",
      },
    },
    {
      selector: "edge",
      style: {
        width: 1.5,
        "line-color": t.base300,
        "target-arrow-color": t.base300,
        "target-arrow-shape": "triangle",
        "curve-style": "unbundled-bezier",
        "control-point-distances": [60],
        "control-point-weights": [0.5],
        label: "data(roundType)",
        "font-family": "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size": 10,
        color: t.baseContent,
        "text-rotation": "autorotate",
        "text-margin-y": -8,
      },
    },
    {
      // Chair edges go between ranks — keep them as standard beziers so
      // they route along the dagre layout cleanly.
      selector: 'edge[roundType = "synthesize"]',
      style: { "curve-style": "bezier" },
    },
    {
      selector: 'edge[roundType = "peer_review"]',
      style: {
        "line-color": t.warning || "#f59e0b",
        "target-arrow-color": t.warning || "#f59e0b",
      },
    },
    {
      selector: 'edge[roundType = "revision"]',
      style: {
        "line-color": t.secondary || "#9333ea",
        "target-arrow-color": t.secondary || "#9333ea",
        "curve-style": "bezier",
        "control-point-step-size": 80,
        "loop-direction": "0deg",
        "loop-sweep": "-90deg",
      },
    },
    {
      selector: 'edge[roundType = "debate"]',
      style: {
        "line-color": t.error || "#ef4444",
        "target-arrow-color": t.error || "#ef4444",
      },
    },
    {
      selector: 'edge[roundType = "synthesize"]',
      style: {
        "line-color": t.primary,
        "target-arrow-color": t.primary,
        width: 2,
      },
    },
    {
      // Input/independent edges: dashed and dimmer to mark "this reads the
      // original input, not a peer's output".
      selector: 'edge[isInput = "true"], edge[roundType = "independent"]',
      style: {
        "line-style": "dashed",
        "line-color": t.base300,
        "target-arrow-color": t.base300,
        opacity: 0.7,
        width: 1,
      },
    },
  ]
}

const ROUNDS_LAYOUT = { name: "dagre", rankDir: "TB", nodeSep: 30, rankSep: 90 }

export const CouncilDiagram = {
  mounted() {
    this.render()

    // Re-style on theme flip (data-theme attribute change on <html>).
    this.themeObserver = new MutationObserver(() => {
      if (this.cy) this.cy.style(buildStyle()).update()
    })
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
  },

  updated() {
    const nextSpec = this.el.dataset.spec
    if (nextSpec !== this._lastSpec) this.render()
  },

  destroyed() {
    if (this.themeObserver) this.themeObserver.disconnect()
    if (this.cy) this.cy.destroy()
  },

  render() {
    const raw = this.el.dataset.spec || "{}"
    this._lastSpec = raw
    let spec
    try {
      spec = JSON.parse(raw)
    } catch (e) {
      console.error("CouncilDiagram: bad spec JSON", e)
      spec = { members: [], rounds: [], chair: null }
    }

    if (this.cy) this.cy.destroy()

    this.cy = cytoscape({
      container: this.el,
      elements: specToElementsRounds(spec),
      style: buildStyle(),
      layout: ROUNDS_LAYOUT,
      autoungrabify: false,
      userZoomingEnabled: true,
      userPanningEnabled: true,
      boxSelectionEnabled: false,
      wheelSensitivity: 0.2,
    })

    this.cy.nodeHtmlLabel([
      {
        query: 'node[kind = "member_round"]',
        halign: "center",
        valign: "center",
        halignBox: "center",
        valignBox: "center",
        tpl: memberRoundCardHtml,
      },
      {
        query: 'node[kind = "input"]',
        halign: "center",
        valign: "center",
        halignBox: "center",
        valignBox: "center",
        tpl: inputNodeHtml,
      },
      {
        query: 'node[kind = "chair"]',
        halign: "center",
        valign: "center",
        halignBox: "center",
        valignBox: "center",
        tpl: chairCardHtml,
      },
    ])
  },
}
