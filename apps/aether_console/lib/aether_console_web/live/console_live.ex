defmodule AetherConsoleWeb.ConsoleLive do
  @moduledoc """
  The console shell: sidebar nav + the Cluster / Buckets / Identity views (Objects
  is a "soon" placeholder). The view is chosen by `@live_action` (one LiveView,
  four routes). Cluster polls live `/cluster` state; Buckets/Identity read and write
  through the cluster's `/admin` API (`AetherConsole.Admin`), refetching after each
  create/delete. Objects is still a placeholder.
  """
  use AetherConsoleWeb, :live_view

  alias AetherConsole.Cluster
  alias AetherConsole.Admin

  @poll_ms 1500

  @impl true
  def mount(_params, _session, socket) do
    action = socket.assigns.live_action
    # Poll live cluster state only on the Cluster view.
    if connected?(socket) and action == :cluster, do: send(self(), :poll)

    socket =
      socket
      |> assign(identity_tab: "users", prev_ops: %{}, buckets: nil, identity: nil)
      |> assign(open_form: nil, notice: nil, minted: nil)
      |> load(action)

    {:ok, socket}
  end

  # Read Buckets / Identity from the cluster's admin API on view entry (navigating
  # to a tab remounts, so this refetches).
  defp load(socket, :buckets), do: assign(socket, buckets: Admin.buckets())

  defp load(socket, :identity),
    do: assign(socket, identity: build_identity(Admin.users(), Admin.keys(), Admin.groups()))

  defp load(socket, _), do: socket

  # Join users with their key counts + group memberships (the admin API returns
  # each list separately).
  defp build_identity({:ok, users}, keys_res, groups_res) do
    keys = ok_list(keys_res)
    groups = ok_list(groups_res)

    enriched =
      Enum.map(users, fn u ->
        name = u["name"]

        %{
          "name" => name,
          "admin" => u["admin"],
          "key_count" => Enum.count(keys, &(&1["user"] == name)),
          "groups" => for(g <- groups, name in (g["members"] || []), do: g["name"])
        }
      end)

    {:ok, %{users: enriched, keys: keys, groups: groups}}
  end

  defp build_identity({:error, reason}, _, _), do: {:error, reason}

  defp ok_list({:ok, l}), do: l
  defp ok_list(_), do: []

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, push_topology(socket, Cluster.snapshot())}
  end

  # No cluster reachable — let the client fall back to its standalone animation.
  defp push_topology(socket, %{connected: false}) do
    push_event(socket, "cluster", %{connected: false})
  end

  defp push_topology(socket, %{connected: true, nodes: nodes, leader: leader}) do
    prev = socket.assigns.prev_ops

    # `/cluster` already reports the full membership including down nodes (Raft config
    # retains them), so we render it as-is — no client-side inference. Per-node rates =
    # the delta in cumulative op counters since the last poll (0 on first sight, so we
    # never replay a node's whole history). The client turns these into a capped
    # number of colored particles — bounded regardless of op volume.
    with_rates = Enum.map(nodes, &Map.put(&1, :rates, rate_delta(prev[&1.name], &1.ops)))
    new_prev = Map.new(nodes, &{&1.name, &1.ops})

    socket
    |> assign(prev_ops: new_prev)
    |> push_event("cluster", %{connected: true, leader: leader, nodes: with_rates})
  end

  # First time we see a node: no baseline yet, so emit no flow (don't replay history).
  defp rate_delta(nil, _cur), do: %{put: 0, repair: 0, read_repair: 0, shed: 0}

  defp rate_delta(prev, cur) do
    %{
      put: max(cur.put - prev.put, 0),
      repair: max(cur.repair - prev.repair, 0),
      read_repair: max(cur.read_repair - prev.read_repair, 0),
      shed: max(cur.shed - prev.shed, 0)
    }
  end

  @impl true
  def handle_event("idtab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, identity_tab: tab, open_form: nil)}
  end

  # Toggle an inline create form open/closed (only one at a time).
  def handle_event("toggle_form", %{"form" => f}, socket) do
    form = String.to_existing_atom(f)
    open = if socket.assigns.open_form == form, do: nil, else: form
    {:noreply, assign(socket, open_form: open, notice: nil)}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, notice: nil, minted: nil)}
  end

  # ── buckets ────────────────────────────────────────────────────────────────
  def handle_event("create_bucket", %{"name" => name}, socket) do
    {:noreply,
     after_write(socket, Admin.create_bucket(String.trim(name)), "Bucket “#{name}” created")}
  end

  def handle_event("delete_bucket", %{"name" => name}, socket) do
    {:noreply, after_write(socket, Admin.delete_bucket(name), "Bucket “#{name}” deleted")}
  end

  # ── users ──────────────────────────────────────────────────────────────────
  def handle_event("create_user", %{"name" => name} = p, socket) do
    admin? = p["admin"] in ["true", "on", true]

    {:noreply,
     after_write(socket, Admin.create_user(String.trim(name), admin?), "User “#{name}” created")}
  end

  def handle_event("delete_user", %{"name" => name}, socket) do
    {:noreply, after_write(socket, Admin.delete_user(name), "User “#{name}” deleted")}
  end

  # ── keys ───────────────────────────────────────────────────────────────────
  def handle_event("mint_key", %{"user" => user}, socket) do
    case Admin.mint_key(user) do
      {:ok, key} ->
        {:noreply, socket |> assign(minted: key, notice: nil) |> reload()}

      err ->
        {:noreply, put_notice(socket, :error, "Mint key: " <> write_error(err))}
    end
  end

  def handle_event("revoke_key", %{"key" => key}, socket) do
    {:noreply, after_write(socket, Admin.revoke_key(key), "Key revoked")}
  end

  # ── groups ─────────────────────────────────────────────────────────────────
  def handle_event("create_group", %{"name" => name}, socket) do
    {:noreply,
     after_write(socket, Admin.create_group(String.trim(name)), "Group “#{name}” created")}
  end

  def handle_event("delete_group", %{"name" => name}, socket) do
    {:noreply, after_write(socket, Admin.delete_group(name), "Group “#{name}” deleted")}
  end

  def handle_event("add_member", %{"group" => group, "user" => user}, socket) do
    {:noreply,
     after_write(socket, Admin.add_member(group, String.trim(user)), "Added #{user} to #{group}")}
  end

  def handle_event("remove_member", %{"group" => group, "user" => user}, socket) do
    {:noreply,
     after_write(socket, Admin.remove_member(group, user), "Removed #{user} from #{group}")}
  end

  # Apply a write result: on success, flash + refetch the current view; on failure,
  # flash the mapped error and leave the data as-is.
  defp after_write(socket, :ok, msg),
    do: socket |> put_notice(:ok, msg) |> assign(open_form: nil) |> reload()

  defp after_write(socket, {:ok, _body}, msg), do: after_write(socket, :ok, msg)
  defp after_write(socket, err, _msg), do: put_notice(socket, :error, write_error(err))

  defp reload(socket), do: load(socket, socket.assigns.live_action)

  defp put_notice(socket, kind, msg), do: assign(socket, notice: {kind, msg})

  defp write_error({:error, :no_token}), do: "no admin token configured on the console"
  defp write_error({:error, :unauthorized}), do: "the cluster rejected the admin token"
  defp write_error({:error, :conflict}), do: "already exists, or the bucket isn’t empty"
  defp write_error({:error, :not_found}), do: "not found (already removed?)"
  defp write_error({:error, :invalid}), do: "invalid name"
  defp write_error(_), do: "the cluster’s admin API is unreachable"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="shell">
      <.sidebar active={@live_action} current_user={@current_user} />
      <main class="content">
        <.cluster :if={@live_action == :cluster} />
        <.buckets
          :if={@live_action == :buckets}
          buckets={@buckets}
          open_form={@open_form}
          notice={@notice}
        />
        <.identity
          :if={@live_action == :identity}
          tab={@identity_tab}
          identity={@identity}
          open_form={@open_form}
          notice={@notice}
          minted={@minted}
        />
        <.objects :if={@live_action == :objects} />
      </main>
    </div>
    """
  end

  # ── sidebar ──────────────────────────────────────────────────────────────
  defp sidebar(assigns) do
    ~H"""
    <aside class="side">
      <div class="brand">
        <span class="mark">aether<b>s3</b></span><span class="ver">console</span>
      </div>
      <div class="nav-label">operate</div>
      <.link navigate={~p"/"} class={["nav", @active == :cluster && "active"]}>
        <svg viewBox="0 0 18 18">
          <circle cx="9" cy="4" r="2" /><circle cx="4" cy="14" r="2" /><circle cx="14" cy="14" r="2" />
          <path d="M8 5.6 5 12M10 5.6 13 12M6 14h6" />
        </svg>
        <span>Cluster</span>
      </.link>
      <div class="nav-label">manage</div>
      <.link navigate={~p"/buckets"} class={["nav", @active == :buckets && "active"]}>
        <svg viewBox="0 0 18 18">
          <path d="M3 5c0-1 2.7-2 6-2s6 1 6 2-2.7 2-6 2-6-1-6-2Z" />
          <path d="M3 5v8c0 1 2.7 2 6 2s6-1 6-2V5" />
        </svg>
        <span>Buckets</span>
      </.link>
      <.link navigate={~p"/identity"} class={["nav", @active == :identity && "active"]}>
        <svg viewBox="0 0 18 18">
          <circle cx="6.5" cy="6.5" r="3.2" /><path d="M8.7 8.7 15 15M12.5 12.5l1.6-1.6M14 14l1.4-1.4" />
        </svg>
        <span>Identity</span>
      </.link>
      <.link navigate={~p"/objects"} class={["nav soon", @active == :objects && "active"]}>
        <svg viewBox="0 0 18 18"><path d="M2.5 5.5h4l1.6 1.8H15.5v7.2h-13Z" /><path d="M2.5 5.5V4h5" /></svg>
        <span>Objects</span><span class="soon-tag">soon</span>
      </.link>
      <div class="side-foot">
        <div class="user-chip">
          <span>as <b>{@current_user.user}</b></span>
          <.form for={%{}} action={~p"/logout"} method="delete">
            <button class="logout" type="submit">sign out</button>
          </.form>
        </div>
        <div class="monitor"><span class="pulse"></span><span class="txt">live monitor</span></div>
      </div>
    </aside>
    """
  end

  # ── cluster (canvas driven by the ClusterField JS hook) ───────────────────
  defp cluster(assigns) do
    ~H"""
    <section class="view active">
      <div class="head">
        <div>
          <h1>Cluster</h1><p>live topology · rendezvous ring · replica flow</p>
        </div>
        <div class="readouts">
          <div class="ro">
            <span class="ro-k">nodes</span><span class="ro-v" id="ro-nodes">—</span>
          </div>
          <div class="ro">
            <span class="ro-k">raft leader</span><span class="ro-v" id="ro-leader">—</span>
          </div>
          <div class="ro">
            <span class="ro-k">ops · s</span><span class="ro-v" id="ro-ops">—</span>
          </div>
        </div>
      </div>
      <div class="cluster-body">
        <canvas id="field" phx-hook="ClusterField" phx-update="ignore"></canvas>
        <div class="rail">
          <div class="glass legend">
            <div class="p-title">replica flow</div>
            <div class="leg-row">
              <span class="ldot" style="background:var(--blue)"></span><span class="leg-label">write · W=1</span>
            </div>
            <div class="leg-row">
              <span class="ldot" style="background:var(--green)"></span><span class="leg-label">read-repair</span>
            </div>
            <div class="leg-row">
              <span class="ldot" style="background:var(--violet)"></span><span class="leg-label">anti-entropy</span>
            </div>
            <div class="leg-row">
              <span class="ldot" style="background:var(--amber)"></span><span class="leg-label">rebalance · shed</span>
            </div>
          </div>
          <div class="glass feed">
            <div class="p-title">telemetry</div><div class="feed-lines" id="feed"></div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ── buckets ───────────────────────────────────────────────────────────────
  defp buckets(assigns) do
    ~H"""
    <section class="view active">
      <div class="head">
        <div>
          <h1>Buckets</h1>
          <p>{bucket_summary(@buckets)}</p>
        </div>
        <div class="head-actions">
          <button class="btn" phx-click="toggle_form" phx-value-form="bucket">+ New bucket</button>
        </div>
      </div>
      <div class="scroll">
        <.notice notice={@notice} />
        <form :if={@open_form == :bucket} class="newform" phx-submit="create_bucket">
          <input
            class="input"
            name="name"
            placeholder="bucket-name (3–63, lowercase)"
            autocomplete="off"
            required
          />
          <button class="btn sm" type="submit">Create</button>
          <button class="btn sm ghost" type="button" phx-click="toggle_form" phx-value-form="bucket">
            Cancel
          </button>
        </form>
        <%= case @buckets do %>
          <% {:ok, list} -> %>
            <div class="panel-box">
              <div class="pb-head"><span class="t">all buckets</span></div>
              <table>
                <thead>
                  <tr>
                    <th>Bucket</th><th>Owner</th><th>Access</th><th>Grants</th><th>Created</th><th>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={b <- list}>
                    <td><span class="name">{b["name"]}</span></td>
                    <td class="mono">{b["owner"] || "—"}</td>
                    <td><.access_chip grants={b["grants"]} /></td>
                    <td><.grant_chips grants={b["grants"]} /></td>
                    <td class="sub-txt">{short_date(b["created_at"])}</td>
                    <td class="actions">
                      <button
                        class="btn sm danger"
                        phx-click="delete_bucket"
                        phx-value-name={b["name"]}
                        data-confirm={"Delete bucket “#{b["name"]}”? It must be empty."}
                      >
                        Delete
                      </button>
                    </td>
                  </tr>
                  <tr :if={list == []}>
                    <td colspan="6" class="sub-txt">no buckets yet</td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% {:error, reason} -> %>
            <.admin_error reason={reason} />
          <% _ -> %>
            <div class="empty">
              <p class="sub-txt">loading…</p>
            </div>
        <% end %>
      </div>
    </section>
    """
  end

  # ── identity (server-side tabs, live from the admin API) ──────────────────
  defp identity(assigns) do
    ~H"""
    <section class="view active">
      <div class="head">
        <div>
          <h1>Identity</h1>
          <p>users · access keys · groups — replicated via the control plane</p>
        </div>
        <div class="head-actions">
          <button
            :if={@tab == "users"}
            class="btn"
            phx-click="toggle_form"
            phx-value-form="user"
          >+ New user</button>
          <button
            :if={@tab == "groups"}
            class="btn"
            phx-click="toggle_form"
            phx-value-form="group"
          >+ New group</button>
        </div>
      </div>
      <div class="scroll">
        <.notice notice={@notice} />
        <.minted_key minted={@minted} />
        <%= case @identity do %>
          <% {:ok, data} -> %>
            <div class="tabs">
              <button
                class={["tab", @tab == "users" && "active"]}
                phx-click="idtab"
                phx-value-tab="users"
              >Users</button>
              <button
                class={["tab", @tab == "keys" && "active"]}
                phx-click="idtab"
                phx-value-tab="keys"
              >Access keys</button>
              <button
                class={["tab", @tab == "groups" && "active"]}
                phx-click="idtab"
                phx-value-tab="groups"
              >Groups</button>
            </div>

            <div :if={@tab == "users"}>
              <form :if={@open_form == :user} class="newform" phx-submit="create_user">
                <input class="input" name="name" placeholder="username" autocomplete="off" required />
                <label class="check"><input type="checkbox" name="admin" /> admin</label>
                <button class="btn sm" type="submit">Create</button>
                <button
                  class="btn sm ghost"
                  type="button"
                  phx-click="toggle_form"
                  phx-value-form="user"
                >Cancel</button>
              </form>
              <div class="panel-box">
                <table>
                  <thead>
                    <tr>
                      <th>User</th><th>Role</th><th class="num">Keys</th><th>Groups</th><th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={u <- data.users}>
                      <td class="name">{u["name"]}</td>
                      <td>
                        <span :if={u["admin"]} class="chip c-admin">admin</span>
                        <span :if={!u["admin"]} class="chip c-priv plain">user</span>
                      </td>
                      <td class="num">{u["key_count"]}</td>
                      <td>
                        <span class="chips">
                          <span :for={g <- u["groups"]} class="chip c-list plain">{g}</span>
                          <span :if={u["groups"] == []} class="sub-txt">—</span>
                        </span>
                      </td>
                      <td class="actions">
                        <button class="btn sm" phx-click="mint_key" phx-value-user={u["name"]}>
                          Mint key
                        </button>
                        <button
                          class="btn sm danger"
                          phx-click="delete_user"
                          phx-value-name={u["name"]}
                          data-confirm={"Delete user “#{u["name"]}” and all its keys?"}
                        >Delete</button>
                      </td>
                    </tr>
                    <tr :if={data.users == []}>
                      <td colspan="5" class="sub-txt">no users</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>

            <div :if={@tab == "keys"} class="panel-box">
              <table>
                <thead>
                  <tr>
                    <th>Access key</th><th>User</th><th>Created</th><th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={k <- data.keys}>
                    <td class="mono">{k["access_key"]}</td>
                    <td class="mono">{k["user"]}</td>
                    <td class="sub-txt">{short_date(k["created_at"])}</td>
                    <td class="actions">
                      <button
                        class="btn sm danger"
                        phx-click="revoke_key"
                        phx-value-key={k["access_key"]}
                        data-confirm="Revoke this access key? Clients using it stop working immediately."
                      >Revoke</button>
                    </td>
                  </tr>
                  <tr :if={data.keys == []}>
                    <td colspan="4" class="sub-txt">no keys</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@tab == "groups"}>
              <form :if={@open_form == :group} class="newform" phx-submit="create_group">
                <input class="input" name="name" placeholder="group name" autocomplete="off" required />
                <button class="btn sm" type="submit">Create</button>
                <button
                  class="btn sm ghost"
                  type="button"
                  phx-click="toggle_form"
                  phx-value-form="group"
                >Cancel</button>
              </form>
              <div class="panel-box">
                <table>
                  <thead>
                    <tr>
                      <th>Group</th><th class="num">Members</th><th>Members</th><th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={g <- data.groups}>
                      <td class="name">{g["name"]}</td>
                      <td class="num">{length(g["members"] || [])}</td>
                      <td>
                        <span class="chips">
                          <span :for={m <- g["members"] || []} class="chip c-priv plain">
                            {m}
                            <button
                              class="x"
                              phx-click="remove_member"
                              phx-value-group={g["name"]}
                              phx-value-user={m}
                              title={"remove #{m}"}
                            >×</button>
                          </span>
                          <span :if={(g["members"] || []) == []} class="sub-txt">—</span>
                        </span>
                      </td>
                      <td class="actions">
                        <form class="rowform" phx-submit="add_member">
                          <input type="hidden" name="group" value={g["name"]} />
                          <input
                            class="input sm"
                            name="user"
                            placeholder="+ add user"
                            autocomplete="off"
                            required
                          />
                        </form>
                        <button
                          class="btn sm danger"
                          phx-click="delete_group"
                          phx-value-name={g["name"]}
                          data-confirm={"Delete group “#{g["name"]}”?"}
                        >Delete</button>
                      </td>
                    </tr>
                    <tr :if={data.groups == []}>
                      <td colspan="4" class="sub-txt">no groups</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          <% {:error, reason} -> %>
            <.admin_error reason={reason} />
          <% _ -> %>
            <div class="empty">
              <p class="sub-txt">loading…</p>
            </div>
        <% end %>
      </div>
    </section>
    """
  end

  # ── objects (soon) ────────────────────────────────────────────────────────
  defp objects(assigns) do
    ~H"""
    <section class="view active">
      <div class="head">
        <div>
          <h1>Objects</h1><p>bucket &amp; prefix browser</p>
        </div>
      </div>
      <div class="empty">
        <svg viewBox="0 0 32 32"><path d="M4 9h9l3 3h12v13H4Z" /><path d="M4 9V6h9" /></svg>
        <h2>Object browser</h2>
        <p>
          Not available yet — shipping right after Cluster, Buckets and Identity. It'll browse
          buckets over the paginated ListObjectsV2 API, with prefix/delimiter “folder” navigation.
        </p>
        <span class="chip c-priv plain">planned</span>
      </div>
    </section>
    """
  end

  # ── shared render helpers for Buckets / Identity ──────────────────────────
  defp access_chip(assigns) do
    {label, cls} = access_label(assigns[:grants] || [])
    assigns = assign(assigns, label: label, cls: cls)

    ~H"""
    <span class={"chip " <> @cls}>{@label}</span>
    """
  end

  defp grant_chips(assigns) do
    ~H"""
    <span class="chips">
      <span :for={g <- @grants || []} class={"chip plain " <> perm_class(g["permission"])}>
        {grantee_label(g["grantee"])} : {g["permission"]}
      </span>
      <span :if={(@grants || []) == []} class="sub-txt">—</span>
    </span>
    """
  end

  defp admin_error(assigns) do
    {title, msg} = admin_error_text(assigns.reason)
    assigns = assign(assigns, title: title, msg: msg)

    ~H"""
    <div class="empty">
      <svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="12" /><path d="M16 9v9M16 22v.4" /></svg>
      <h2>{@title}</h2>
      <p>{@msg}</p>
    </div>
    """
  end

  # Transient result banner (dismissible). Nil renders nothing.
  defp notice(%{notice: nil} = assigns), do: ~H""

  defp notice(assigns) do
    {kind, msg} = assigns.notice
    assigns = assign(assigns, kind: kind, msg: msg)

    ~H"""
    <div class={["banner", @kind == :error && "err"]}>
      <span>{@msg}</span>
      <button class="x" phx-click="dismiss" title="dismiss">×</button>
    </div>
    """
  end

  # The minted secret is returned exactly once by the cluster — surface it until
  # dismissed, then it's gone for good (only the encrypted form is stored).
  defp minted_key(%{minted: nil} = assigns), do: ~H""

  defp minted_key(assigns) do
    ~H"""
    <div class="banner keyout">
      <div>
        <div class="p-title">new access key — copy the secret now, it won't be shown again</div>
        <div class="secret">access key&nbsp; <b>{@minted["access_key"]}</b></div>
        <div class="secret">secret key&nbsp;&nbsp; <b>{@minted["secret_key"]}</b></div>
      </div>
      <button class="x" phx-click="dismiss" title="dismiss">×</button>
    </div>
    """
  end

  defp access_label(grants) do
    everyone = for %{"grantee" => "everyone", "permission" => p} <- grants, do: p

    cond do
      "write" in everyone -> {"public-read-write", "c-pubrw"}
      "get" in everyone -> {"public-read", "c-pubr"}
      grants == [] -> {"private", "c-priv"}
      true -> {"custom", "c-priv"}
    end
  end

  defp grantee_label("everyone"), do: "everyone"
  defp grantee_label("user:" <> n), do: n
  defp grantee_label("group:" <> n), do: n
  defp grantee_label(other), do: other

  defp perm_class("get"), do: "c-get"
  defp perm_class("write"), do: "c-write"
  defp perm_class("list"), do: "c-list"
  defp perm_class("full"), do: "c-full"
  defp perm_class(_), do: "c-priv"

  defp short_date(nil), do: "—"
  defp short_date(iso) when is_binary(iso), do: String.slice(iso, 0, 10)
  defp short_date(_), do: "—"

  defp bucket_summary({:ok, list}) do
    n = length(list)
    "#{n} bucket#{if n == 1, do: "", else: "s"}"
  end

  defp bucket_summary(_), do: "—"

  defp admin_error_text(:no_token),
    do:
      {"Admin token not set",
       "Set AETHER_CONSOLE_ADMIN_TOKEN on the console (matching the cluster's AETHER_ADMIN_TOKEN) to manage identity and buckets."}

  defp admin_error_text(:unauthorized),
    do:
      {"Not authorized",
       "The cluster rejected the admin token — check it matches AETHER_ADMIN_TOKEN."}

  defp admin_error_text(_),
    do:
      {"Cluster unreachable",
       "Couldn't reach the cluster's admin API — check AETHER_CONSOLE_NODES."}
end
