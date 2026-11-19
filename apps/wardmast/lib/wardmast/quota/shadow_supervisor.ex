defmodule Wardmast.Quota.ShadowSupervisor do
  @moduledoc """
  Isolates the shadow-only quota components (`Wardmast.Quota.Budget.Server`) from
  the application's supervision tree (bd-1p8cxk).

  v0.2.42 crash-looped: a `Budget.Server` that raised on every recompute
  exhausted the top-level supervisor's restart intensity, and the application
  shut down. A budget component must never be able to do that: under
  DC8's seat admission admission reads the published budgets
  (`Wardmast.Accounts.SeatCheck`, DC8), and a table that is gone reads as no
  budget, which leaves the account ceilings to decide. Two layers:

    * the children restart under a supervisor with a very permissive intensity,
      so a crashing server does not take its siblings or this supervisor down;
    * this supervisor is itself `restart: :temporary` in `Wardmast.Supervisor`:
      should it ever give up, nobody restarts it and, being temporary, its exit
      is not counted against the parent's intensity. The app stays up without
      the shadow budgets.
  """

  use Supervisor

  @doc "`:server_opts` are handed to `Wardmast.Quota.Budget.Server` (tests)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    children = [{Wardmast.Quota.Budget.Server, Keyword.get(opts, :server_opts, [])}]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1_000, max_seconds: 1)
  end
end
