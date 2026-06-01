defmodule Mix.Tasks.Concilio.ResetToken do
  @moduledoc """
  Generates a new Concilio auth token, writes it to the auth token
  file (mode 0600), updates `app_state.token_hash`, and rotates the
  session secret so any active sessions are invalidated.

  The file lives in the per-env data dir, so under `mix phx.server`
  (dev) it lands in `priv/.dev/auth_token` — not `~/.concilio/`, which
  is the prod / menubar-app path. See `Concilio.Auth.TokenStore`. The
  printed `Written to:` line is always authoritative. The menubar app
  bootstraps its own token, so this task is mainly a dev / recovery
  tool.

  ## Usage

      mix concilio.reset_token

  Pass `--yes` to skip the overwrite confirmation prompt:

      mix concilio.reset_token --yes
  """

  use Mix.Task

  alias Concilio.Auth
  alias Concilio.Auth.Token
  alias Concilio.Auth.TokenStore

  @shortdoc "Reset the Concilio auth token"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [yes: :boolean])
    skip_confirm? = Keyword.get(opts, :yes, false)

    Mix.Task.run("app.start")

    if existing_token_file?() and not skip_confirm? do
      confirm_or_abort!()
    end

    token = Token.generate()
    hash = Token.hash(token)

    TokenStore.write!(token)
    {:ok, _} = Auth.put_token_hash(hash)
    _ = Auth.rotate_secret!()

    Mix.shell().info("""

    New auth token:

      #{token}

    Written to: #{TokenStore.file_path()} (mode 0600)
    Active sessions have been invalidated.
    """)
  end

  defp existing_token_file? do
    File.regular?(TokenStore.file_path())
  end

  defp confirm_or_abort! do
    answer = Mix.shell().yes?("Overwrite existing #{TokenStore.file_path()}?")

    unless answer do
      Mix.raise("Aborted; token left unchanged.")
    end
  end
end
