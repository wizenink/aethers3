defmodule AetherConsoleWeb.SessionController do
  @moduledoc """
  Login/logout. `create` verifies a cluster credential via `AetherConsole.Auth`
  and, on success, stores only the resolved `%{user, admin}` in the session (the
  secret is used to prove identity and then dropped — see `AetherConsoleWeb.Auth`).
  """
  use AetherConsoleWeb, :controller

  alias AetherConsole.Auth
  alias AetherConsoleWeb.Auth, as: WebAuth

  def new(conn, _params) do
    render(conn, :new, error: nil, access_key: "")
  end

  def create(conn, %{"access_key" => access_key, "secret_key" => secret})
      when is_binary(access_key) and is_binary(secret) do
    case Auth.verify(access_key, secret) do
      {:ok, %{user: user, admin: admin}} ->
        conn
        |> renew_session()
        |> put_session(WebAuth.session_key(), %{"user" => user, "admin" => admin})
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> render(:new, error: message(reason), access_key: access_key)
    end
  end

  def create(conn, _params) do
    render(conn, :new, error: "Access key and secret are required.", access_key: "")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  # Rotate the session id on privilege change (fixation defense) while keeping the
  # session so the freshly-set identity survives the redirect.
  defp renew_session(conn), do: configure_session(conn, renew: true)

  defp message(:invalid), do: "Invalid access key or secret."

  defp message(:not_admin),
    do: "That credential is valid but not an admin — console access requires an admin identity."

  defp message(:unavailable), do: "No cluster node reachable. Check AETHER_CONSOLE_NODES."
  defp message(_), do: "Login failed."
end
