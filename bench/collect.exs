# BEAM introspection collector for the AetherS3 benchmark harness.
#
# Runs as a short-lived distributed "observer" node that connects to every
# cluster node (discovered from the admin /cluster endpoint) and reads raw ERTS
# microstate accounting + counters over :erpc. No runtime_tools / :msacc needed —
# microstate accounting is a core emulator feature, so this works against the
# stock published image.
#
# Two phases wrap a warp run so the numbers cover exactly that window:
#   elixir --name observer@<ip> --cookie <c> collect.exs start <admin_url> <state_dir>
#   <run warp>
#   elixir --name observer@<ip> --cookie <c> collect.exs stop  <admin_url> <state_dir> <out.md>
#
# msacc tells you which subsystem you're bound by: high `emulator` on normal
# schedulers = CPU/app-bound; high `check_io` = socket/network; busy
# `dirty_io_scheduler` = disk (CubDB/blobs); high `gc` = allocation churn; high
# `sleep` everywhere = not saturated (add concurrency, or the limit is elsewhere).

defmodule Bench.Collect do
  @report_types [:scheduler, :dirty_cpu_scheduler, :dirty_io_scheduler]
  # Order states most-to-least useful for reading the table left to right.
  @states [:emulator, :gc, :check_io, :port, :aux, :other, :sleep]

  def main(["start", admin, state_dir]) do
    nodes = discover(admin)
    File.mkdir_p!(state_dir)

    for n <- nodes do
      # Enable, then reset so counters start clean for this window.
      :erpc.call(n, :erlang, :system_flag, [:microstate_accounting, true])
      :erpc.call(n, :erlang, :system_flag, [:microstate_accounting, :reset])
      snap = counters(n)
      File.write!(Path.join(state_dir, safe(n) <> ".t0"), :erlang.term_to_binary(snap))
    end

    IO.puts("collector: armed msacc on #{length(nodes)} node(s): #{inspect(nodes)}")
  end

  def main(["stop", admin, state_dir, out]) do
    nodes = discover(admin)

    reports =
      for n <- nodes do
        msacc = :erpc.call(n, :erlang, :statistics, [:microstate_accounting])
        t1 = counters(n)
        t0 = state_dir |> Path.join(safe(n) <> ".t0") |> File.read!() |> :erlang.binary_to_term()
        %{node: n, msacc: summarize(msacc), delta: delta(t0, t1)}
      end

    md = render(reports)
    File.write!(out, md)
    IO.puts(md)
    IO.puts("collector: wrote #{out}")
  end

  def main(_),
    do: abort("usage: collect.exs start <admin_url> <state_dir> | stop <admin_url> <state_dir> <out.md>")

  # --- node discovery (regex over /cluster JSON; no JSON dep needed) ----------

  defp discover(admin) do
    :inets.start()
    url = String.to_charlist("#{String.trim_trailing(admin, "/")}/cluster")

    body =
      case :httpc.request(:get, {url, []}, [{:timeout, 5000}], body_format: :binary) do
        {:ok, {{_, 200, _}, _headers, body}} -> body
        other -> abort("cannot read #{admin}/cluster: #{inspect(other)}")
      end

    nodes =
      Regex.scan(~r/aether@[\d.]+/, body)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&String.to_atom/1)

    if nodes == [], do: abort("no aether@ nodes found in /cluster response")

    for n <- nodes, Node.connect(n) != true, do: abort("cannot connect to #{n} (cookie/network?)")
    nodes
  end

  # --- raw counters (deltas over the window) ----------------------------------

  defp counters(n) do
    {reductions, _} = :erpc.call(n, :erlang, :statistics, [:reductions])
    {{:input, input}, {:output, output}} = :erpc.call(n, :erlang, :statistics, [:io])
    {gcs, words_reclaimed, _} = :erpc.call(n, :erlang, :statistics, [:garbage_collection])

    %{
      reductions: reductions,
      io_in: input,
      io_out: output,
      gcs: gcs,
      words_reclaimed: words_reclaimed,
      run_queue: :erpc.call(n, :erlang, :statistics, [:run_queue]),
      mem_total: :erpc.call(n, :erlang, :memory, [:total])
    }
  end

  defp delta(t0, t1) do
    %{
      reductions: t1.reductions - t0.reductions,
      io_in_mb: mb(t1.io_in - t0.io_in),
      io_out_mb: mb(t1.io_out - t0.io_out),
      gcs: t1.gcs - t0.gcs,
      reclaimed_mb: mb((t1.words_reclaimed - t0.words_reclaimed) * :erlang.system_info(:wordsize)),
      run_queue_end: t1.run_queue,
      mem_total_mb: mb(t1.mem_total)
    }
  end

  # --- microstate accounting summary ------------------------------------------

  # Sum counters per state within each scheduler type, then turn into percentages.
  # Returns %{type => %{busy: pct, states: %{state => pct}}}.
  defp summarize(msacc) do
    for type <- @report_types, into: %{} do
      totals =
        msacc
        |> Enum.filter(&(&1.type == type))
        |> Enum.reduce(%{}, fn %{counters: c}, acc ->
          Map.merge(acc, c, fn _k, a, b -> a + b end)
        end)

      grand = totals |> Map.values() |> Enum.sum()
      states = for {s, v} <- totals, into: %{}, do: {s, pct(v, grand)}
      {type, %{busy: 100.0 - Map.get(states, :sleep, 0.0), states: states}}
    end
  end

  # --- rendering --------------------------------------------------------------

  defp render(reports) do
    header = "## BEAM introspection (per node, over the run window)\n"

    body =
      Enum.map_join(reports, "\n", fn %{node: n, msacc: m, delta: d} ->
        """
        ### #{n}

        | scheduler type | busy % | #{Enum.map_join(@states, " | ", &Atom.to_string/1)} |
        |---|---|#{String.duplicate("---|", length(@states))}
        #{Enum.map_join(@report_types, "\n", fn t -> msacc_row(t, m[t]) end)}

        - reductions: #{fmt(d.reductions)}   gc runs: #{fmt(d.gcs)}   reclaimed: #{d.reclaimed_mb} MB
        - io in: #{d.io_in_mb} MB   io out: #{d.io_out_mb} MB
        - run queue at end: #{inspect(d.run_queue_end)}   beam mem: #{d.mem_total_mb} MB
        """
      end)

    header <> "\n" <> body
  end

  defp msacc_row(type, nil), do: "| #{type} | (none) | #{String.duplicate("| ", length(@states))}"

  defp msacc_row(type, %{busy: busy, states: states}) do
    cells = Enum.map_join(@states, " | ", fn s -> f1(Map.get(states, s, 0.0)) end)
    "| #{type} | **#{f1(busy)}** | #{cells} |"
  end

  # --- helpers ----------------------------------------------------------------

  defp pct(_v, 0), do: 0.0
  defp pct(v, grand), do: Float.round(v * 100 / grand, 1)
  defp f1(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
  defp safe(node), do: node |> Atom.to_string() |> String.replace(~r/[^\w.-]/, "_")

  defp fmt(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end

  defp abort(msg) do
    IO.puts(:stderr, "collector error: #{msg}")
    System.halt(1)
  end
end

Bench.Collect.main(System.argv())
