defmodule ConcilioWeb.HealthController do
  @moduledoc """
  Liveness probe used by the Tauri shell to detect when the
  Phoenix endpoint is ready before opening the WebView. Also
  useful for Docker / Fly health checks. Intentionally bypasses
  the auth pipeline so the shell can poll without a session.

  Returns a constant 200 + text payload. Do not embed runtime
  state here — anything that fails would block startup.
  """
  use ConcilioWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
