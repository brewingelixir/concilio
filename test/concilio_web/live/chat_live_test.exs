defmodule ConcilioWeb.ChatLiveTest do
  use ConcilioWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Concilio.Auth
  alias Concilio.Chats
  alias Concilio.Providers
  alias Concilio.Repo

  setup %{conn: conn} do
    _ = Auth.rotate_secret!()

    {:ok, _} = Providers.set_enabled(:openai, true)
    {:ok, _} = Providers.set_api_key(:openai, "sk-test")
    {:ok, _} = Providers.add_user_model(:openai, "gpt-4o-mini")

    conn = Plug.Test.init_test_session(conn, %{concilio_session: Auth.session_secret!()})
    %{conn: conn}
  end

  describe "model picker" do
    test "renders working-set models grouped by provider", %{conn: conn} do
      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:gpt-4o-mini"
        })

      {:ok, _lv, html} = live(conn, ~p"/c/#{conv.id}")

      assert html =~ ~s(<optgroup label="openai">)
      assert html =~ ~s(value="openai:gpt-4o-mini")
      assert html =~ ~s(selected)
    end

    test "set_model updates conversation.default_model", %{conn: conn} do
      {:ok, _} = Providers.add_user_model(:openai, "gpt-4o")

      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:gpt-4o-mini"
        })

      {:ok, lv, _html} = live(conn, ~p"/c/#{conv.id}")

      render_hook(lv, "set_model", %{
        "conversation" => %{"default_model" => "openai:gpt-4o"}
      })

      assert Repo.reload(conv).default_model == "openai:gpt-4o"
      assert render(lv) =~ ~s(value="openai:gpt-4o" selected)
    end

    test "stale stored model still rendered as selected", %{conn: conn} do
      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:retired-model"
        })

      {:ok, _lv, html} = live(conn, ~p"/c/#{conv.id}")

      assert html =~ "openai:retired-model (not in working set)"
      assert html =~ ~s(value="openai:retired-model")
    end

    test "supervised worker stamps the placeholder with the provider error", %{conn: conn} do
      # Valid working-set model so resolve_responder succeeds, but no
      # CouncilEx provider runtime configured -> the supervised worker
      # records a `:error` status on the placeholder message.
      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:gpt-4o-mini"
        })

      :ok = Phoenix.PubSub.subscribe(Concilio.PubSub, "concilio:chat:" <> conv.id)

      {:ok, lv, _html} = live(conn, ~p"/c/#{conv.id}")

      log =
        capture_log(fn ->
          lv
          |> form("#composer-form", %{"composer" => %{"text" => "hello there"}})
          |> render_submit()

          assert_receive {:plain_message_updated, _msg_id}, 5_000
        end)

      assert log =~ "plain_completion provider error"
      assert log =~ "401"

      [pending_msg] =
        Chats.list_messages(conv.id)
        |> Enum.filter(&match?(%Concilio.Chats.Message{role: :assistant}, &1))

      assert pending_msg.status == :error
      assert pending_msg.content != ""
    end

    test "shows pending bubble with elapsed timer while worker runs", %{conn: conn} do
      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:gpt-4o-mini"
        })

      :ok = Phoenix.PubSub.subscribe(Concilio.PubSub, "concilio:chat:" <> conv.id)

      {:ok, lv, _html} = live(conn, ~p"/c/#{conv.id}")

      capture_log(fn ->
        html =
          lv
          |> form("#composer-form", %{"composer" => %{"text" => "hi"}})
          |> render_submit()

        # Pending bubble renders inline per-message: spinner + elapsed timer.
        assert html =~ ~s(loading loading-dots)
        assert html =~ ~s(phx-hook="ElapsedTimer")
        assert html =~ ~s(data-start-ms=)

        # Await the worker so its DB writes/logs land inside the sandbox
        # window (otherwise late finalize races test teardown).
        assert_receive {:plain_message_updated, _msg_id}, 5_000
      end)
    end

    test "composer textarea has Cmd+Enter hint and phx-hook", %{conn: conn} do
      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:gpt-4o-mini"
        })

      {:ok, _lv, html} = live(conn, ~p"/c/#{conv.id}")

      assert html =~ ~s(phx-hook="ComposerKeys")
      assert html =~ "Enter to send, Shift+Enter for newline"
    end

    test "rejects unknown label not in working set", %{conn: conn} do
      {:ok, conv} =
        Chats.create_conversation(%{
          title: "Test",
          default_responder_kind: :model,
          default_model: "openai:gpt-4o-mini"
        })

      {:ok, lv, _html} = live(conn, ~p"/c/#{conv.id}")

      html =
        render_hook(lv, "set_model", %{
          "conversation" => %{"default_model" => "anthropic:nonexistent"}
        })

      assert html =~ "Unknown model."
      assert Repo.reload(conv).default_model == "openai:gpt-4o-mini"
    end
  end
end
