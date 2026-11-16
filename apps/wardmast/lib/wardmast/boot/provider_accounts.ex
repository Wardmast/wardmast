defmodule Wardmast.Boot.ProviderAccounts do
  @moduledoc """
  Classify this install's provider-account posture for this boot
  (bd-cvvb02; P13, bd-9gqj8e) — see `Wardmast.Accounts.Enablement` for the
  rule.

  Mirrors `Wardmast.Boot.ConfigMigrator`: a one-shot synchronous worker that
  returns `:ignore`, placed after the schema and config migrators so it reads
  a current schema, and before the boot tasks that start the per-workspace
  queues. The *resolution* is read-only and runs on every instance, so a
  duplicate boot reports the same `Enablement.status/0`; the
  fresh-install `<provider>:default` joins are writes, so only the
  `Wardmast.SingleInstance` primary makes them.

  Never aborts the boot: a failure is logged and nothing is auto-joined.
  """

  require Logger

  alias Wardmast.Accounts.Enablement
  alias Wardmast.SingleInstance

  @doc "A one-shot temporary worker — nothing to restart."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Classify the install, then — on the primary instance of a fresh install —
  join every existing workspace to `<provider>:default`. Always `:ignore`.

  `:primary?` overrides the `Wardmast.SingleInstance.primary?/0` lookup (for
  tests); it is evaluated at start time so `Wardmast.Application.children/1`
  stays a pure spec builder.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    Enablement.resolve()

    if Enablement.auto_join?() and Keyword.get_lazy(opts, :primary?, &SingleInstance.primary?/0) do
      Enablement.join_defaults()
    end

    :ignore
  rescue
    e ->
      Logger.error("Boot.ProviderAccounts: #{Exception.format(:error, e, __STACKTRACE__)}")
      :ignore
  end
end
