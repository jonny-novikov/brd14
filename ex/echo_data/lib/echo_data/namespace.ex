defmodule EchoData.Namespace do
  @moduledoc """
  The namespace registry (bcs2.1): the single home of the namespace *policy*,
  beside the shape rules in `EchoData.BrandedId` (which this rung leaves
  byte-identical) and the pure gate `EchoData.Bcs.gate/2`.

  Two spaces, one rule with one home (`docs/echo/bcs/appendixes/bcs.namespaces.md`):
  the **3-letter space is the platform registry** — curated rows below; an
  unregistered 3-letter code is reserved, platform-owned, not available to
  applications — and the **4-letter space is developer-space**, classified
  `:developer` today while the wire still refuses it (the bcs2 developer-space
  dossier records the admission blast radius).

  `classify/1` is **total**: any term answers exactly one of
  `{:platform, tag}` · `:reserved` · `:developer` · `:invalid`, and never raises.
  A census row classifies `{:platform, tag}` unless it is `:parked` — a parked
  code folds to `:reserved` (withheld by ruling, not a mintable kind), exactly as
  an unregistered code does; `status/1` carries the finer distinction
  (`:reserved` by decision · `:parked` by ruling · `:unregistered` by default).

  Pure and total by construction: the census compiles into function heads —
  no process, no ETS, no seed step, no connection. The census is **additive**
  after ship: retirement is a status flip to `:retired` (carried by the enum
  from day one), never a row deletion.

      iex> EchoData.Namespace.classify("JOB")
      {:platform, :job}
      iex> EchoData.Namespace.classify("XYZ")
      :reserved
      iex> EchoData.Namespace.classify("SHOP")
      :developer
      iex> EchoData.Namespace.classify("LO")
      :invalid
      iex> EchoData.Namespace.status("LOG")
      :reserved
      iex> EchoData.Namespace.status("ZZZ")
      :unregistered
  """

  @typedoc "A census row's status. `:retired` is carried from day one; no row uses it yet."
  @type row_status :: :active | :reserved | :parked | :retired

  @typedoc "A census row: `{code, space, program, semantics, status}`."
  @type row :: {String.t(), :platform, String.t(), String.t(), row_status()}

  # The census (awk.6 — 30 active · 1 reserved · 1 parked; the awk.1 APP row, the
  # awk.4a TRC activation, and the awk.6 REQ addition + COR flip), seeded
  # verbatim. TRC is ACTIVE by the awk.4a F1 Operator ruling — the observability
  # triad's trace row is mintable so ech's BCS-branded trace plane carries
  # census-gated TRC ids.
  # REQ is ACTIVE by the awk.6 census act (req-proxy-design D-1): the
  # api.anthropic.com egress record plane mints one REQ id per proxied exchange —
  # the entity is the api request/response exchange, not an inbound shell request.
  # COR is ACTIVE by the awk.6 Phase B flip (ADR-P7, req-proxy-design D-4): the
  # correlation slot fills ONLY from a VALIDATED inbound declaration — a consumer
  # mints a COR id and declares it; the proxy validates and records, never mints.
  # LOG alone stays reserved
  # BY DECISION — the last withheld observability row; source:
  # docs/echo/bcs/appendixes/bcs.namespaces.md ("The observability triad").
  # OBX is parked BY RULING — mq4.3 ADR-B (docs/echo_mq_v4/specs/mq4/mq4.3.md),
  # recorded verbatim: "no `OBX` namespace is minted — a 14-byte brand is a
  # permanent public contract".
  # TUN is a documented false positive (TUNNEL_TOKEN env strings in
  # go/jonnify-tunnel, not a branded prefix) and is deliberately NOT seeded.
  @registry [
    {"JOB", :platform, "echo_mq", "queue job", :active},
    {"EVT", :platform, "echo_mq", "stream event record", :active},
    {"GRP", :platform, "echo_mq", "lane group", :active},
    {"ARC", :platform, "echo_data", "archetype bundle", :active},
    {"VOL", :platform, "echo_data (graft)", "volume", :active},
    {"SEG", :platform, "echo_data (graft)", "segment", :active},
    {"CMT", :platform, "echo_data (graft)", "commit / version", :active},
    {"WFL", :platform, "echo_store", "workflow", :active},
    {"BAT", :platform, "echo_store", "batch", :active},
    {"PRT", :platform, "echo_store", "flow parent", :active},
    {"AST", :platform, "echo_store", "intent subject (asset)", :active},
    {"CFG", :platform, "echo_store", "config entity", :active},
    {"MSG", :platform, "echo_relay", "live message tag", :active},
    {"USR", :platform, "accounts", "operator / user", :active},
    {"PLR", :platform, "codemojex", "player", :active},
    {"SES", :platform, "codemojex", "session", :active},
    {"GAM", :platform, "codemojex", "game", :active},
    {"ROM", :platform, "codemojex", "room", :active},
    {"GES", :platform, "codemojex", "guess", :active},
    {"EMS", :platform, "codemojex", "emoji set", :active},
    {"PKG", :platform, "codemojex", "key-shop package", :active},
    {"ORD", :platform, "codemojex", "key-shop order", :active},
    {"TXN", :platform, "codemojex", "wallet transaction", :active},
    {"RVL", :platform, "codemojex", "wallet reversal", :active},
    {"OTX", :platform, "codemojex", "key-shop order transaction", :active},
    {"NOT", :platform, "codemojex", "notification job", :active},
    {"LOG", :platform, "observability", "log line", :reserved},
    {"TRC", :platform, "observability", "trace span", :active},
    {"COR", :platform, "observability", "correlation id", :active},
    {"REQ", :platform, "observability", "api request/response", :active},
    {"OBX", :platform, "echo_store", "outbox brand — REFUSED; the intent is an edge", :parked},
    {"APP", :platform, "awkernel", "dual-app identity", :active}
  ]

  # The classify tag per registered code. Five tags are pinned literally by the
  # appendix's example block (LOG :log · TRC :trace · COR :correlation ·
  # USR :user · SES :session); the rest follow the same pattern — the kind's
  # core noun from the census semantics. A parked row's tag is recorded but
  # unused: `classify/1` folds `:parked` to `:reserved`.
  @tags %{
    "JOB" => :job,
    "EVT" => :event,
    "GRP" => :group,
    "ARC" => :archetype,
    "VOL" => :volume,
    "SEG" => :segment,
    "CMT" => :commit,
    "WFL" => :workflow,
    "BAT" => :batch,
    "PRT" => :parent,
    "AST" => :asset,
    "CFG" => :config,
    "MSG" => :message,
    "USR" => :user,
    "PLR" => :player,
    "SES" => :session,
    "GAM" => :game,
    "ROM" => :room,
    "GES" => :guess,
    "EMS" => :emoji_set,
    "PKG" => :package,
    "ORD" => :order,
    "TXN" => :transaction,
    "RVL" => :reversal,
    "OTX" => :order_transaction,
    "NOT" => :notification,
    "LOG" => :log,
    "TRC" => :trace,
    "COR" => :correlation,
    "REQ" => :request,
    "OBX" => :outbox,
    "APP" => :app
  }

  # Compile-time census integrity: unique codes, and tags covering exactly the census.
  codes = for {code, _, _, _, _} <- @registry, do: code

  if length(Enum.uniq(codes)) != length(codes) do
    raise CompileError, description: "EchoData.Namespace census carries a duplicate code"
  end

  if not MapSet.equal?(MapSet.new(codes), MapSet.new(Map.keys(@tags))) do
    raise CompileError, description: "EchoData.Namespace @tags does not cover the census exactly"
  end

  @active_codes for {code, _, _, _, :active} <- @registry, do: code

  @doc """
  Classifies any term into exactly one of the four namespace shapes — total,
  never raises.

  A registered, non-parked code answers `{:platform, tag}`; a parked code and
  any unregistered well-formed 3-letter code answer `:reserved`; a well-formed
  4-letter code answers `:developer`; everything else is `:invalid`.
  """
  @spec classify(term()) :: {:platform, atom()} | :reserved | :developer | :invalid
  for {code, _space, _program, _semantics, status} <- @registry do
    if status == :parked do
      def classify(unquote(code)), do: :reserved
    else
      def classify(unquote(code)), do: {:platform, unquote(Map.fetch!(@tags, code))}
    end
  end

  def classify(<<a, b, c>>) when a in ?A..?Z and b in ?A..?Z and c in ?A..?Z, do: :reserved

  def classify(<<a, b, c, d>>)
      when a in ?A..?Z and b in ?A..?Z and c in ?A..?Z and d in ?A..?Z,
      do: :developer

  def classify(_), do: :invalid

  @doc """
  The census status of a code: `:active` · `:reserved` (by decision) ·
  `:parked` (by ruling) · `:retired` (a flip, never a deletion) — and
  `:unregistered` for any term without a row, distinguishing the default
  reservation from a recorded decision. Total, never raises.
  """
  @spec status(term()) :: row_status() | :unregistered
  for {code, _space, _program, _semantics, status} <- @registry do
    def status(unquote(code)), do: unquote(status)
  end

  def status(_), do: :unregistered

  @doc "The owning program of a registered code, or `nil` without a row. Total."
  @spec program(term()) :: String.t() | nil
  for {code, _space, program, _semantics, _status} <- @registry do
    def program(unquote(code)), do: unquote(program)
  end

  def program(_), do: nil

  @doc "The recorded semantics of a registered code, or `nil` without a row. Total."
  @spec semantics(term()) :: String.t() | nil
  for {code, _space, _program, semantics, _status} <- @registry do
    def semantics(unquote(code)), do: unquote(semantics)
  end

  def semantics(_), do: nil

  @doc "True only for a code whose census row is `:active` — the mint gate the audit enforces."
  @spec active?(term()) :: boolean()
  for {code, _space, _program, _semantics, :active} <- @registry do
    def active?(unquote(code)), do: true
  end

  def active?(_), do: false

  @doc "Every seeded census row, in census order: `{code, space, program, semantics, status}`."
  @spec all() :: [row()]
  def all, do: @registry

  @doc "The active codes, in census order."
  @spec active_codes() :: [String.t()]
  def active_codes, do: @active_codes
end
