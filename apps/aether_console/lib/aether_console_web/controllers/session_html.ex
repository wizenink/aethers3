defmodule AetherConsoleWeb.SessionHTML do
  use AetherConsoleWeb, :html

  def new(assigns) do
    ~H"""
    <div class="login">
      <div class="login-card">
        <div class="login-brand">
          <span class="mark">aether<b>s3</b></span><span class="ver">console</span>
        </div>
        <p class="login-sub">Sign in with a cluster admin access key.</p>

        <div :if={@error} class="banner err">{@error}</div>

        <.form for={%{}} action={~p"/login"} method="post" class="login-form">
          <label class="login-label" for="access_key">Access key</label>
          <input
            class="input"
            id="access_key"
            type="text"
            name="access_key"
            value={@access_key}
            autocomplete="username"
            autofocus
            placeholder="AKIA…"
          />
          <label class="login-label" for="secret_key">Secret key</label>
          <input
            class="input"
            id="secret_key"
            type="password"
            name="secret_key"
            autocomplete="current-password"
            placeholder="secret"
          />
          <button class="btn" type="submit">Sign in</button>
        </.form>
      </div>
    </div>
    """
  end
end
