defmodule Wardmast.Doctor.Platform do
  @moduledoc """
  What `arb server doctor` needs to know about the host the *server* runs on
  (`GET /api/server/platform`): its OS, the PATH it hands workers, and where the
  worker tools resolve on that PATH.

  The doctor CLI may run on a different machine (`WARDMAST_HOST`) and from an
  interactive shell whose PATH differs from the launchd-started server's, so the
  platform and tool lookups are answered here, on the server, never by the CLI.
  """

  alias Wardmast.Worker.SpawnEnv

  @tools ~w(gtimeout claude gh glab mise)

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    os = Keyword.get_lazy(opts, :os, &:os.type/0)
    home = Keyword.get_lazy(opts, :home, fn -> System.get_env("HOME") end)
    base = Keyword.get_lazy(opts, :path, fn -> System.get_env("PATH") end)
    {path, _appended} = SpawnEnv.darwin_baseline_path(base, os, home)
    path = path || ""
    find = Keyword.get(opts, :find, &find_executable/2)

    %{
      os: os_name(os),
      path: path,
      tools: Map.new(@tools, &{&1, find.(&1, path)})
    }
  end

  defp os_name({:unix, name}), do: Atom.to_string(name)
  defp os_name({_family, name}), do: Atom.to_string(name)

  defp find_executable(name, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end

  defp executable?(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
