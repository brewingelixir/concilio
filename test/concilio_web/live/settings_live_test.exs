defmodule ConcilioWeb.SettingsLiveTest do
  use ConcilioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Concilio.Auth
  alias Concilio.Providers
  alias Concilio.Providers.Model
  alias Concilio.Repo

  # The JS.push `:confirm` regression slipped past us once because no
  # test rendered SettingsLive. These tests are the smoke layer: every
  # tab must render without a server-side crash, and the provider
  # remove flow has to round-trip end-to-end.

  setup %{conn: conn} do
    _ = Auth.rotate_secret!()

    conn = Plug.Test.init_test_session(conn, %{concilio_session: Auth.session_secret!()})
    %{conn: conn}
  end

  describe "render" do
    for path <- [
          "/settings/providers",
          "/settings/about",
          "/settings/defaults",
          "/settings/display"
        ] do
      test "GET #{path} renders without raising", %{conn: conn} do
        {:ok, _lv, html} = live(conn, unquote(path))

        # Page rendered. Specific copy is brittle; just confirm we
        # got the SettingsLive shell.
        assert html =~ "Settings"
      end
    end

    test "provider card shows 'setup needed' when no API key is set", %{conn: conn} do
      # Provider added (enabled flag = true) but no key yet.
      {:ok, _} = Providers.set_enabled(:openai, true)

      {:ok, _lv, html} = live(conn, ~p"/settings/providers")

      assert html =~ "setup needed"
      refute html =~ ~s(badge-success)
    end

    test "provider card shows 'select model' when key is set but nothing in working set", %{
      conn: conn
    } do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")

      {:ok, _lv, html} = live(conn, ~p"/settings/providers")

      assert html =~ "select model"
      refute html =~ "run model test"
      refute html =~ ~s(badge-success)
    end

    test "provider card shows 'run model test' once a model is in the working set", %{conn: conn} do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")
      {:ok, _} = Providers.add_user_model(:openai, "gpt-5.4-mini")

      mark_model_in_working_set!(:openai, "gpt-5.4-mini")

      {:ok, _lv, html} = live(conn, ~p"/settings/providers")

      assert html =~ "run model test"
      refute html =~ ~s(badge-success)
    end

    test "providers tab flips to 'working' once a model has tested ok", %{conn: conn} do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")
      {:ok, _} = Providers.add_user_model(:openai, "gpt-5.4-mini")
      mark_model_tested!(:openai, "gpt-5.4-mini")

      {:ok, _lv, html} = live(conn, ~p"/settings/providers")

      assert html =~ "working"
      assert html =~ ~s(badge-success)
    end
  end

  describe "remove flow" do
    test "X button removes a not-yet-working provider", %{conn: conn} do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")

      {:ok, lv, _html} = live(conn, ~p"/settings/providers")

      selector = ~s(button[phx-click="provider_remove"][phx-value-provider="openai"])
      assert has_element?(lv, selector)

      lv |> element(selector) |> render_click()

      # Setting + any rows cleared.
      assert Repo.get_by(Providers.Setting, provider: :openai) == nil
      assert Repo.all(from(m in Model, where: m.provider == ^:openai)) == []
    end

    test "X button on a working provider carries data-confirm", %{conn: conn} do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")
      {:ok, _} = Providers.add_user_model(:openai, "gpt-5.4-mini")
      mark_model_tested!(:openai, "gpt-5.4-mini")

      {:ok, _lv, html} = live(conn, ~p"/settings/providers")

      # Confirm payload is present in the DOM. Phoenix's bundled JS
      # reads `data-confirm` and prompts before pushing the click.
      assert html =~ ~s(data-confirm="Remove openai? This deletes)
    end
  end

  defp mark_model_tested!(provider, model_id) do
    Model
    |> Repo.get_by!(provider: provider, model_id: model_id)
    |> Model.changeset(%{last_test_status: :ok, in_working_set: true})
    |> Repo.update!()
  end

  defp mark_model_in_working_set!(provider, model_id) do
    Model
    |> Repo.get_by!(provider: provider, model_id: model_id)
    |> Model.changeset(%{in_working_set: true})
    |> Repo.update!()
  end
end
