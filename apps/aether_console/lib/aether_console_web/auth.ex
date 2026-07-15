defmodule AetherConsoleWeb.Auth do
  @moduledoc """
  Session-based access control for the console.

  Login happens in `SessionController` (verify a cluster credential → put the
  resolved `%{user, admin}` in the session). Everything the console renders lives
  behind LiveView, so the gate is a `live_session` `on_mount` hook: no session user
  → redirect to `/login`; otherwise assign `current_user`.

  Phase 1 note: only the identity (`%{user, admin}`) is stored — never the secret.
  The console makes no act-as-user call yet, so there's nothing to sign; the acting
  credential arrives with self-service (Phase 2).
  """
  import Phoenix.LiveView, only: [redirect: 2]
  import Phoenix.Component, only: [assign: 3]

  @session_key "console_user"

  @doc "Session key holding the logged-in identity map (shared with SessionController)."
  def session_key, do: @session_key

  def on_mount(:require_user, _params, session, socket) do
    case session[@session_key] do
      %{"user" => user} = id ->
        {:cont, assign(socket, :current_user, %{user: user, admin: id["admin"] == true})}

      _ ->
        {:halt, redirect(socket, to: "/login")}
    end
  end
end
