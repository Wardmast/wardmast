defmodule WardmastWeb.NodeFixtures do
  @moduledoc """
  Test fixtures for the node join flow: a deploy data home laid out the way
  `arb server deploy` leaves it, with a retained published tarball.
  """

  @doc """
  Lay out `<home>/releases/<tag>/` (an OTP-release-shaped tree with a
  `bin/wardmast` script), the retained `<tag>.tar.gz` + `.sha256`, and the
  `current` symlink. Returns `%{home:, tag:, tarball:, sha256:}`.
  """
  @spec install_release!(String.t(), String.t(), keyword()) :: map()
  def install_release!(home, tag \\ "v9.9.9", opts \\ []) do
    releases = Path.join(home, "releases")
    tree = Path.join(releases, tag)
    File.mkdir_p!(Path.join(tree, "bin"))
    File.write!(Path.join(tree, "bin/wardmast"), "#!/bin/sh\necho agent #{tag}\n")
    File.chmod!(Path.join(tree, "bin/wardmast"), 0o755)

    tarball = Path.join(releases, tag <> ".tar.gz")
    staging = Path.join(home, "staging-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(staging, "wardmast/bin"))
    File.cp!(Path.join(tree, "bin/wardmast"), Path.join(staging, "wardmast/bin/wardmast"))
    File.chmod!(Path.join(staging, "wardmast/bin/wardmast"), 0o755)

    # `layout: :flat` is a hand-rolled `--local` tarball with no top-level dir.
    entries =
      case Keyword.get(opts, :layout, :rooted) do
        :rooted -> [{~c"wardmast", String.to_charlist(Path.join(staging, "wardmast"))}]
        :flat -> [{~c"bin", String.to_charlist(Path.join(staging, "wardmast/bin"))}]
      end

    :ok = :erl_tar.create(String.to_charlist(tarball), entries, [:compressed])

    File.rm_rf!(staging)

    sha = :crypto.hash(:sha256, File.read!(tarball)) |> Base.encode16(case: :lower)
    File.write!(tarball <> ".sha256", sha <> "  arbiter-#{tag}-linux.tar.gz\n")
    File.ln_s!(tree, Path.join(home, "current"))

    %{home: home, tag: tag, tarball: tarball, sha256: sha}
  end

  @doc "Point `Wardmast.Nodes.Agent.data_home/0` at `home`; restores on exit."
  @spec use_data_home!(String.t()) :: :ok
  def use_data_home!(home) do
    previous = Application.fetch_env(:wardmast, :data_dir)
    Application.put_env(:wardmast, :data_dir, home)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end
    end)
  end
end
