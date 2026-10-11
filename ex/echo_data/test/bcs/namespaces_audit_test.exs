defmodule EchoData.Bcs.NamespacesAuditTest do
  @moduledoc """
  The census audit (bcs2.1 R2): every 3-letter namespace code minted anywhere in the
  umbrella must be an `active` row in `EchoData.Namespace` — registered-or-red.

  One fast pass over every umbrella app's `lib/` + `test/` (`../*/lib`, `../*/test`
  relative to this app's dir; `docs/` is never scanned — the walk is rooted at the
  apps tree). The scan captures the three mint forms with a quoted 3-letter code
  (`generate!/1`, `next_branded/1`, `encode!/2`); the registry module itself is the
  one skipped file. The registry lookup is guarded by `Code.ensure_loaded?/1` so a
  missing registry FAILS this test naming the offenders (the rung's RED-first
  bootstrap) instead of crashing with `UndefinedFunctionError`.
  """

  use ExUnit.Case, async: true

  # __DIR__ = echo/apps/echo_data/test/bcs → three up = echo/apps
  @apps_dir Path.expand("../../..", __DIR__)

  # The single skipped file: the registry itself (its rows quote every code).
  @registry_file "echo_data/lib/echo_data/namespace.ex"

  # The three mint forms (bcs2.1.llms.md, References). Each capture requires the
  # closing quote right after three uppercase letters, so a 4-letter developer
  # code never matches. The regex sources here cannot self-match: the escaped
  # `\(` in each sigil breaks the literal call shape. (A function, not a module
  # attribute: a compiled Regex carries a reference and cannot be attribute-injected.)
  defp mint_forms do
    [
      ~r/generate!\(\s*"([A-Z]{3})"/,
      ~r/next_branded\(\s*"([A-Z]{3})"/,
      ~r/encode!\(\s*"([A-Z]{3})"\s*,/
    ]
  end

  test "every minted 3-letter namespace code is an active row in EchoData.Namespace" do
    minted = minted_codes()

    # A scan that captures nothing is a dead audit, not a green one.
    assert map_size(minted) > 0,
           "the audit captured no mint sites under #{@apps_dir} — " <>
             "the wildcard or the mint-form regexes are broken"

    offenders =
      minted
      |> Enum.reject(fn {code, _site} -> registered_active?(code) end)
      |> Enum.sort()

    assert offenders == [],
           """
           #{length(offenders)} minted namespace code(s) are not active in EchoData.Namespace:

           #{Enum.map_join(offenders, "\n", fn {code, site} -> "  #{code}  (first mint site: #{site})" end)}

           Register each code as an active row in EchoData.Namespace — the census
           (docs/echo/bcs/appendixes/bcs.namespaces.md) — or retire the mint site.
           """
  end

  # code => first mint site (app-relative path), one read per file.
  defp minted_codes do
    @apps_dir
    |> Path.join("*/{lib,test}/**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, @registry_file))
    |> Enum.reduce(%{}, fn file, acc ->
      content = File.read!(file)

      Enum.reduce(mint_forms(), acc, fn regex, acc ->
        regex
        |> Regex.scan(content, capture: :all_but_first)
        |> Enum.reduce(acc, fn [code], acc ->
          Map.put_new(acc, code, Path.relative_to(file, @apps_dir))
        end)
      end)
    end)
  end

  # Guarded lookup: absent registry → false for every code → the failure message
  # names the offenders (never an UndefinedFunctionError crash). `apply/3` keeps
  # the pre-registry compile warning-free.
  defp registered_active?(code) do
    Code.ensure_loaded?(EchoData.Namespace) and apply(EchoData.Namespace, :active?, [code])
  end
end
