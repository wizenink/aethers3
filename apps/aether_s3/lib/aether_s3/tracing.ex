defmodule AetherS3.Tracing do
  @moduledoc """
  Thin OpenTelemetry helpers for AetherS3.

  Tracing is **inert unless an OTLP endpoint is configured** (see runtime.exs:
  `OTEL_EXPORTER_OTLP_ENDPOINT`). When off, `span/3` and `rpc/4` bypass
  OpenTelemetry entirely — no spans, no context injection, no extra `:erpc`
  indirection — so the hot path is byte-for-byte what it was before.

  `rpc/4` is the piece that makes tracing *distributed*: `:erpc` runs the callee
  on a remote node in a fresh process with none of the caller's OpenTelemetry
  context, so a naive remote call produces an orphan span. We inject the active
  context into a W3C carrier, ship it as an argument, and re-attach it on the
  remote node before opening the span — linking the replica's work to the
  request that caused it.
  """
  require OpenTelemetry.Tracer, as: Tracer

  @doc "Whether trace export is enabled (an OTLP exporter is configured)."
  @spec enabled?() :: boolean
  def enabled?, do: Application.get_env(:opentelemetry, :traces_exporter, :none) != :none

  @doc """
  Wrap `fun` so it runs with the *current* trace context re-attached — for work
  handed to another process (e.g. `Task.start`), which otherwise starts with no
  context and produces an orphan trace. A no-op (returns `fun` unchanged) when
  disabled.
  """
  @spec bind((-> result)) :: (-> result) when result: var
  def bind(fun) do
    if enabled?() do
      ctx = :otel_ctx.get_current()

      fn ->
        _ = :otel_ctx.attach(ctx)
        fun.()
      end
    else
      fun
    end
  end

  @doc "Run `fun` inside a span named `name` with `attrs`; a no-op when disabled."
  @spec span(String.t(), map(), (-> result)) :: result when result: var
  def span(name, attrs \\ %{}, fun) do
    if enabled?() do
      Tracer.with_span name, %{attributes: attrs} do
        fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  `:erpc.call(node, mod, fun, args)` wrapped in a CLIENT span, propagating trace
  context so `node` records a linked SERVER span. Falls back to a plain
  `:erpc.call` when tracing is disabled.
  """
  @spec rpc(node(), String.t(), map(), {module(), atom(), list()}) :: term()
  def rpc(node, name, attrs, {mod, fun, args}) do
    if enabled?() do
      attrs = Map.put(attrs, :"peer.node", to_string(node))

      Tracer.with_span name, %{kind: :client, attributes: attrs} do
        carrier = :otel_propagator_text_map.inject([])
        :erpc.call(node, __MODULE__, :__handle_rpc__, [carrier, name, {mod, fun, args}])
      end
    else
      :erpc.call(node, mod, fun, args)
    end
  end

  @doc false
  # Runs on the remote node: re-attach the propagated context, then open a server
  # span around the actual work.
  def __handle_rpc__(carrier, name, {mod, fun, args}) do
    token = :otel_propagator_text_map.extract(carrier)

    try do
      Tracer.with_span name, %{kind: :server} do
        apply(mod, fun, args)
      end
    after
      :otel_ctx.detach(token)
    end
  end
end
