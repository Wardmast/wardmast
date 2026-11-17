defmodule Wardmast.NodeAgent.PodChannel.BootBundle do
  @moduledoc """
  The response to a redeemed `/boot` nonce (`docs/design/remote-workers.md`
  §16 K§10.1, K§12): a tar the pod's `seed` init container unpacks into a
  memory `emptyDir`. It is the only way the run's secrets reach the pod, and it
  is built in memory from the validated `Wardmast.NodeAgent.RunSpec`, so they are
  never a Kubernetes object, never in the pod spec and never on the
  controller's disk.

  | entry | content |
  |---|---|
  | `tls/<bridge>.crt`, `.key` | the run's leaf for each bridge in its spec (`CN` run, `OU` bridge) |
  | `tls/control.crt`, `.key` | the leaf for `:9444` (seed, checkpoint, transcripts, commands) |
  | `secrets.env` | the spec's `secrets` as `export NAME='value'` lines (mode `0600`), as `Wardmast.NodeAgent.Secrets.render/1` writes them |
  | `secret_files/<name>` | the spec's `secret_files` (bd-b2t0kw: agy's service-account key, its MCP config), mode `0600`; `seed` keeps them at `/run/arb/creds/<name>` |
  | `secret_links` | one `<name> <link>` line per secret file that names a `link` (a path under the config dir). **No secret** |
  | `worktree/<path>` | the spec's worktree seed files (`.mcp.json` with the worker-tier bearer, `.claude/skills/…`) |
  | `config_dir/<name>` | the spec's config-dir files (`settings.json`, `CLAUDE.md`) |
  | `prompt/<n>` | the spec's prompt mounts, in order |
  | `manifest.json` | the run id, checkout settings, bridge names, the session transcript to fetch (a resume) and where each prompt goes. **No secret.** |
  """

  alias Wardmast.NodeAgent.PodChannel.BootBundle.Tar
  alias Wardmast.NodeAgent.PodChannel.Cert
  alias Wardmast.NodeAgent.{RunSpec, Secrets}

  @doc "The tar for `spec`, with `leaves` (`%{ou => cert}`) as minted for the run."
  @spec build(RunSpec.t(), %{String.t() => Cert.t()}) :: binary()
  def build(%RunSpec{} = spec, leaves) do
    prompts = for %{kind: "prompt"} = m <- spec.mounts, do: m

    entries =
      [{"manifest.json", Jason.encode!(manifest(spec, prompts)), 0o644}] ++
        tls(leaves) ++
        secrets(spec.secrets) ++
        secret_files(spec.secret_files) ++ seed_files(spec.mounts) ++ prompts(prompts)

    Tar.encode(entries)
  end

  defp manifest(spec, prompts) do
    %{
      "run" => spec.run,
      "checkout" => checkout(spec.checkout),
      "bridges" => Enum.map(spec.bridges, & &1.name),
      "session" => session(spec.mounts),
      "prompts" =>
        prompts
        |> Enum.with_index()
        |> Enum.map(fn {m, i} -> %{"file" => "prompt/#{i}", "path" => m.path} end)
    }
  end

  # The transcript a `--resume` continues (bd-4ic681): the seed container fetches it
  # through the controller (`GET /session`) and checks it against `bytes` and `sha256`.
  defp session(mounts) do
    case Enum.find(mounts, &(&1.kind == "config_dir")) do
      %{session: %{path: path, bytes: bytes, sha256: sha}} ->
        %{"path" => path, "bytes" => bytes, "sha256" => sha}

      _ ->
        nil
    end
  end

  defp checkout(nil), do: nil

  defp checkout(%{branch: branch, base: base, interval_ms: ms}),
    do: %{"branch" => branch, "base" => base, "interval_s" => div(ms, 1000)}

  defp tls(leaves) do
    leaves
    |> Enum.sort()
    |> Enum.flat_map(fn {name, cert} ->
      [
        {"tls/#{name}.crt", Cert.pem_cert(cert.der), 0o644},
        {"tls/#{name}.key", Cert.pem_key(cert.key), 0o600}
      ]
    end)
  end

  defp secrets(secrets) when map_size(secrets) == 0, do: []
  defp secrets(secrets), do: [{"secrets.env", Secrets.render(secrets), 0o600}]

  defp secret_files(files) when map_size(files) == 0, do: []

  defp secret_files(files) do
    sorted = Enum.sort(files)
    links = for {name, %{link: link}} <- sorted, is_binary(link), do: "#{name} #{link}\n"

    for({name, %{content: bytes}} <- sorted, do: {"secret_files/#{name}", bytes, 0o600}) ++
      if(links == [], do: [], else: [{"secret_links", Enum.join(links), 0o644}])
  end

  defp seed_files(mounts) do
    for %{kind: kind, files: files} <- mounts,
        kind in ["worktree", "config_dir"],
        {name, bytes} <- Enum.sort(files),
        do: {"#{kind}/#{name}", bytes, 0o600}
  end

  defp prompts(prompts) do
    prompts |> Enum.with_index() |> Enum.map(fn {m, i} -> {"prompt/#{i}", m.content, 0o600} end)
  end
end
