defmodule Concilio.CouncilsStaticResyncTest do
  use Concilio.DataCase, async: false

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Repo

  # Single module whose __council__/0 result is swappable via the
  # process dictionary, so the sync path sees the same module name +
  # different specs across calls.
  defmodule SwappableStatic do
    def __council__, do: Process.get(:fake_council_spec, %{member: "alpha"})
  end

  setup do
    Process.put(:fake_council_spec, %{member: "alpha", provider: "old"})
    :ok
  end

  test "first sync inserts version 1 with the current spec" do
    Concilio.Councils.__sync_one_for_test__(SwappableStatic)

    assert [v1] = Repo.all(TemplateVersion)
    assert v1.version == 1
    assert v1.spec_json["provider"] == "old"
  end

  test "second sync with same spec returns the same version row" do
    Concilio.Councils.__sync_one_for_test__(SwappableStatic)
    [v1] = Repo.all(TemplateVersion)

    Concilio.Councils.__sync_one_for_test__(SwappableStatic)

    assert [^v1] = Repo.all(TemplateVersion)
  end

  test "spec drift inserts a new version and flips current_version_id" do
    Concilio.Councils.__sync_one_for_test__(SwappableStatic)
    [v1] = Repo.all(TemplateVersion)

    Process.put(:fake_council_spec, %{member: "alpha", provider: "new"})
    Concilio.Councils.__sync_one_for_test__(SwappableStatic)

    versions = Repo.all(from(v in TemplateVersion, order_by: v.version))
    assert length(versions) == 2
    [_v1_persisted, v2] = versions
    assert v2.version == 2
    assert v2.spec_json["provider"] == "new"

    template = Repo.one!(from(t in Template))
    assert template.current_version_id == v2.id
    refute template.current_version_id == v1.id
  end
end
