defmodule Wardmast.NodeAgent.K8s.AgyFacts do
  @moduledoc """
  The two halves of a cluster controller's `caps.agy` (bd-b2t0kw), as the primary last
  reported them in `GET /nodes/cluster` (`Wardmast.Nodes.ClusterInstall.controller_facts/1`):

    * `image` — a published worker image lists `gemini` in `arbiter.cli-providers`, so
      a pod can run agy at all;
    * `credential` — the primary holds a Google Cloud service-account key it hands this
      node's agy pods, per run, through `/boot` (`ContainerSpawn.prepare_remote/1`: the
      run spec's `secret_files`, kept on the pod's memory volume).

  `caps/1` is what `hello` and every heartbeat say: `%{"agy" => true}` when both hold,
  else `%{"agy" => false, "agy_missing" => "image" | "credential"}` (the image first: with
  no agy in the image a key changes nothing). Placement reads them per node
  (`Wardmast.Nodes.Placement.agy_ready?/1`).

  The boot's facts are recorded here (`Wardmast.NodeAgent.K8s.Boot`) and refreshed each
  time the readiness canary asks the primary for its image (every 10 minutes), so a key
  registered, or an agy image published, after the controller connected is advertised
  by its next heartbeat. Held in `:persistent_term`, written only when the value
  changes. Booleans only: nothing here is a credential.
  """

  @key {__MODULE__, :facts}

  @type facts :: %{image: boolean(), credential: boolean()}

  @doc "Record the primary's latest facts (`nil` forgets them)."
  @spec put(facts() | nil) :: :ok
  def put(nil) do
    _ = :persistent_term.erase(@key)
    :ok
  end

  def put(%{} = facts) do
    facts = %{
      image: Map.get(facts, :image) == true,
      credential: Map.get(facts, :credential) == true
    }

    if :persistent_term.get(@key, nil) != facts, do: :persistent_term.put(@key, facts)
    :ok
  end

  @doc "The latest recorded facts, else `fallback` (the boot's), else neither half."
  @spec get(facts() | nil) :: facts()
  def get(fallback \\ nil) do
    :persistent_term.get(@key, nil) || fallback || %{image: false, credential: false}
  end

  @doc "`caps.agy` (and `caps.agy_missing`) for `facts`, as `hello` and `hb` carry them."
  @spec caps(facts()) :: map()
  def caps(%{image: true, credential: true}), do: %{"agy" => true}
  def caps(%{image: true}), do: %{"agy" => false, "agy_missing" => "credential"}
  def caps(_facts), do: %{"agy" => false, "agy_missing" => "image"}
end
