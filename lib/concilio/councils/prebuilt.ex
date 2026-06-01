defmodule Concilio.Councils.Prebuilt do
  @moduledoc """
  Curated `CouncilEx.Councils.*` topology scaffolds (Specialist,
  Consensus, Tournament, WeightedConsensus, JuryWithRetry, …).

  These are *not* DB templates: they ship as data describing a known
  topology + sane round defaults. Surfaced on `/councils` with the
  `:prebuilt` tag; clicking one navigates to the dynamic builder
  (`/councils/new?prebuilt=<slug>`) seeded with the topology so the
  user fills in members + chair.
  """

  @type t :: %{
          slug: String.t(),
          name: String.t(),
          module: String.t(),
          description: String.t(),
          rounds: [map()],
          suggested_members: pos_integer(),
          chair_prompt: String.t()
        }

  @prebuilts [
    %{
      slug: "parallel-panel",
      name: "Parallel Panel",
      module: "CouncilEx.Councils.ParallelPanel",
      description:
        "All members analyse the input in parallel; the chair synthesizes. Topology #1.",
      rounds: [%{"type" => "independent_analysis", "opts" => %{}}],
      suggested_members: 2,
      chair_prompt: "Synthesize the parallel analyses into a single integrated answer."
    },
    %{
      slug: "specialist",
      name: "Specialist",
      module: "CouncilEx.Councils.Specialist",
      description:
        "Specialist members → peer review → chair synthesis. Each member analyses through their own lens, then cross-reviews. Topology #6.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "peer_review", "opts" => %{}}
      ],
      suggested_members: 3,
      chair_prompt: "Synthesize the specialists' peer-reviewed analyses into a final answer."
    },
    %{
      slug: "peer-review",
      name: "Peer Review",
      module: "CouncilEx.Councils.PeerReview",
      description:
        "Drafter → reviewer critique → peer-review pass → chair. One member drafts, others critique, then everyone sees the critiques. Topology #4.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "critique", "opts" => %{}},
        %{"type" => "peer_review", "opts" => %{}}
      ],
      suggested_members: 3,
      chair_prompt: "Edit and synthesize the peer-reviewed draft into a polished final answer."
    },
    %{
      slug: "voting",
      name: "Voting",
      module: "CouncilEx.Councils.Voting",
      description:
        "Independent analysis → structured vote (with aggregator) → chair synthesizes from the outcome. Topology #5.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "vote", "opts" => %{}}
      ],
      suggested_members: 3,
      chair_prompt: "Synthesize a final answer that reflects the vote outcome."
    },
    %{
      slug: "consensus",
      name: "Consensus",
      module: "CouncilEx.Councils.Consensus",
      description:
        "Independent analysis → iterative critique until convergence (or max iterations) → chair. Topology #9.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "iterate", "opts" => %{"max_iterations" => 3}}
      ],
      suggested_members: 2,
      chair_prompt: "Synthesize the converged outputs into a single consensus answer."
    },
    %{
      slug: "tournament",
      name: "Tournament",
      module: "CouncilEx.Councils.Tournament",
      description:
        "Pairwise elimination bracket judged by the chair until one member remains. Chair then synthesizes from the winner. Topology #7.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "pairwise_elimination", "opts" => %{}}
      ],
      suggested_members: 4,
      chair_prompt: "Judge each pair and synthesize a final answer from the bracket winner."
    },
    %{
      slug: "weighted-consensus",
      name: "Weighted Consensus",
      module: "CouncilEx.Councils.WeightedConsensus",
      description:
        "Members analyse in parallel; chair synthesises with per-member weights surfaced in its prompt. Static `:weight` opt or `:confidence` field, normalized.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "synthesis", "opts" => %{}}
      ],
      suggested_members: 2,
      chair_prompt:
        "Synthesize a final answer, prioritising higher-weighted/higher-confidence contributions."
    },
    %{
      slug: "jury-with-retry",
      name: "Jury With Retry",
      module: "CouncilEx.Councils.JuryWithRetry",
      description:
        "K judges run independently; aggregate confidence below threshold triggers a re-sample. Chair synthesizes the final iteration.",
      rounds: [
        %{"type" => "independent_analysis", "opts" => %{}},
        %{"type" => "iterate", "opts" => %{"max_iterations" => 2}}
      ],
      suggested_members: 3,
      chair_prompt: "Synthesize the jury's final-iteration verdicts into a single answer."
    }
  ]

  @doc "All curated prebuilt scaffolds, in display order."
  @spec list() :: [t()]
  def list, do: @prebuilts

  @doc "Lookup a scaffold by slug. Returns `nil` if unknown."
  @spec get(String.t()) :: t() | nil
  def get(slug) when is_binary(slug), do: Enum.find(@prebuilts, &(&1.slug == slug))
  def get(_), do: nil
end
