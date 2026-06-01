defmodule Concilio.CouncilsSamplesTest do
  use Concilio.DataCase, async: false

  alias Concilio.Councils.Template
  alias Concilio.Repo

  defmodule WithSamples do
    def __council__, do: %{member: "alpha"}

    def samples do
      [
        %{title: "T1", input: "Question one"},
        %{title: "T2", input: "Question two", context: "Some context"}
      ]
    end
  end

  defmodule NoSamples do
    def __council__, do: %{member: "alpha"}
  end

  defmodule BadSamples do
    def __council__, do: %{member: "alpha"}
    def samples, do: [%{title: "Empty", input: "  "}, %{title: "OK", input: "Real"}]
  end

  test "static module exposing samples/0 persists normalized samples on the template" do
    Concilio.Councils.__sync_one_for_test__(WithSamples)

    [t] = Repo.all(Template)

    assert [
             %{"title" => "T1", "input" => "Question one"} = first,
             %{"title" => "T2", "input" => "Question two", "context" => "Some context"}
           ] = t.samples

    refute Map.has_key?(first, "context")
  end

  test "module without samples/0 stores empty list" do
    Concilio.Councils.__sync_one_for_test__(NoSamples)
    [t] = Repo.all(Template)
    assert t.samples == []
  end

  test "blank/whitespace-only inputs are dropped" do
    Concilio.Councils.__sync_one_for_test__(BadSamples)
    [t] = Repo.all(Template)
    assert [%{"title" => "OK", "input" => "Real"}] = t.samples
  end
end
