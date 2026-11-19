defmodule WardmastWeb.PairEntry do
  @moduledoc """
  The **Pair** actions on the ticket page (bd-7p6a9o): *Pair on this ticket*,
  and — while the ticket's pair session lives — *Done* and *End*.

  Each is one call into `Wardmast.Sessions.Pair`, which owns the rules, plus
  the flash that tells the operator what happened: the session itself appears
  in the dock, a different LiveView, so a silent page would read as a dead
  button. The dock is reached the way the Refine button reaches it
  (`Wardmast.Sessions.request_open/1`; see `WardmastWeb.RefineEntry`).

  Done can run for minutes — the repo's pre-push checks — so the page starts
  it as an async task and reports through `done_result/2` when it lands.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Wardmast.Sessions
  alias Wardmast.Sessions.Pair
  alias Wardmast.Tasks.Issue

  @doc """
  Whether `issue` should be offered *Pair on this ticket*: the predicate
  `Wardmast.Sessions.Pair.open/2` enforces, so the button never appears where
  the server would refuse it.
  """
  @spec eligible?(Issue.t() | nil) :: boolean()
  defdelegate eligible?(issue), to: Pair

  @doc "Launch or reopen `issue`'s pair session, open it in the dock, and say which."
  @spec open(Phoenix.LiveView.Socket.t(), Issue.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket, %Issue{} = issue) do
    case Pair.open(issue) do
      {:ok, %{session: session, reopened?: reopened?}} ->
        _ = Sessions.request_open(session.id)
        put_flash(socket, :info, opened_message(reopened?))

      {:error, reason} ->
        put_flash(socket, :error, Pair.describe_error(reason))
    end
  end

  @doc "End `issue`'s pair session without Done, and say what was kept."
  @spec close(Phoenix.LiveView.Socket.t(), Issue.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket, %Issue{} = issue) do
    case Pair.close(issue) do
      {:ok, _ended} ->
        put_flash(
          socket,
          :info,
          "Ended the pair session. Its worktree and branch are kept for whoever picks the " <>
            "ticket up next."
        )

      {:error, reason} ->
        put_flash(socket, :error, Pair.describe_error(reason))
    end
  end

  @doc "Flash Done's outcome — `Wardmast.Sessions.Pair.finish/2`'s result."
  @spec done_result(Phoenix.LiveView.Socket.t(), {:ok, map()} | {:error, term()}) ::
          Phoenix.LiveView.Socket.t()
  def done_result(socket, {:ok, %{route: :running}}),
    do: put_flash(socket, :info, "Done is still running; this page updates when it lands.")

  def done_result(socket, {:ok, %{route: :in_review}}),
    do:
      put_flash(
        socket,
        :info,
        "Done: the work is with the ReviewGate. On approval its PR opens, labelled " <>
          "pair-authored, and goes through CI and the merge queue."
      )

  def done_result(socket, {:ok, _result}),
    do:
      put_flash(
        socket,
        :info,
        "Done: the PR is open, labelled pair-authored, and in the merge queue's hands."
      )

  def done_result(socket, {:error, reason}),
    do: put_flash(socket, :error, Pair.describe_error(reason))

  @doc "*Pair on this ticket*."
  attr :id, :string, required: true
  attr :rest, :global

  def pair_button(assigns) do
    ~H"""
    <WardmastWeb.CoreComponents.Core.button
      id={@id}
      size="sm"
      variant="secondary"
      phx-click="pair"
      title="Open a hands-on agent session in this ticket's worktree, and work it together"
      {@rest}
    >
      <:icon><WardmastWeb.CoreComponents.Core.icon name="hero-user-group-mini" /></:icon>
      Pair on this ticket
    </WardmastWeb.CoreComponents.Core.button>
    """
  end

  @doc "*Done* — the pair session's finish. Disabled while one is running."
  attr :id, :string, required: true
  attr :finishing, :boolean, default: false

  attr :variant, :string,
    default: "primary",
    doc: "secondary where the region already has its primary (Backlog's Move to Ready)"

  attr :rest, :global

  def done_button(assigns) do
    ~H"""
    <WardmastWeb.CoreComponents.Core.button
      id={@id}
      size="sm"
      variant={@variant}
      phx-click="pair_done"
      disabled={@finishing}
      title="Commit gate, then the PR (pair-authored), ReviewGate, CI and the merge queue"
      {@rest}
    >
      <:icon><WardmastWeb.CoreComponents.Core.icon name="hero-check-circle-mini" /></:icon>
      {if @finishing, do: "Running Done…", else: "Done"}
    </WardmastWeb.CoreComponents.Core.button>
    """
  end

  @doc "*End* — end the pair session without Done."
  attr :id, :string, required: true
  attr :rest, :global

  def end_button(assigns) do
    ~H"""
    <WardmastWeb.CoreComponents.Core.button
      id={@id}
      size="sm"
      variant="secondary"
      phx-click="pair_end"
      data-confirm="End the pair session without Done? The worktree and branch are kept."
      title="End the session without Done; the worktree and branch are kept"
      {@rest}
    >
      <:icon><WardmastWeb.CoreComponents.Core.icon name="hero-stop-circle-mini" /></:icon>
      End pairing
    </WardmastWeb.CoreComponents.Core.button>
    """
  end

  defp opened_message(true), do: "Reopened this ticket's pair session in the dock."

  defp opened_message(false),
    do: "Launched a pair session in this ticket's worktree — see the dock."
end
