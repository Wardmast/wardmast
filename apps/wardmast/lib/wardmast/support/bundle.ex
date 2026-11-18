defmodule Wardmast.Support.Bundle do
  @moduledoc """
  Diagnostics bundle (`arb support bundle`, the dashboard's "Download
  diagnostics" button): a `.tar.gz` of the server's version, a doctor
  snapshot, its redacted config and the tail of its log, for attaching to a
  bug report.

  Every text file passes through `Wardmast.Redaction.redact_patterns/1`
  (known credential shapes), and config values whose key looks like a secret
  (`secret`, `token`, `password`, `key`, `cookie`, `credential`, `auth`) are
  masked outright, so a bundle is safe to share.

  Options: `:extra_files` (a `%{name => text}` map of client-side files, e.g.
  the CLI's `arb doctor` check results; names are restricted to
  `[A-Za-z0-9._-]+`, stored under `client/`, and redacted like the rest).
  For tests: `:log_path`, `:config` (keyword to render instead of the
  `:wardmast` application env), `:log_bytes`.
  """

  alias Wardmast.Redaction

  @default_log_bytes 256 * 1024
  @secret_key ~r/secret|token|password|passwd|key|cookie|credential|auth/i

  @spec build(keyword()) :: {:ok, %{filename: String.t(), data: binary()}} | {:error, term()}
  def build(opts \\ []) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    entries = for {name, content} <- files(opts), do: {String.to_charlist(name), content}

    path = Path.join(System.tmp_dir!(), "arb-bundle-#{System.unique_integer([:positive])}.tgz")

    try do
      with :ok <- :erl_tar.create(String.to_charlist(path), entries, [:compressed]),
           {:ok, data} <- File.read(path) do
        {:ok, %{filename: "arb-support-bundle-#{stamp}.tar.gz", data: data}}
      end
    after
      File.rm(path)
    end
  end

  @doc "The redacted `{name, content}` files that go into the bundle."
  @spec files(keyword()) :: [{String.t(), String.t()}]
  def files(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> Application.get_all_env(:wardmast) end)
    log_path = Keyword.get_lazy(opts, :log_path, &Wardmast.Config.Paths.server_log_path/0)
    log_bytes = Keyword.get(opts, :log_bytes, @default_log_bytes)

    [
      {"version.txt", version_text()},
      {"doctor.txt", doctor_text()},
      {"config.txt", inspect(mask(config), pretty: true, limit: :infinity, printable_limit: 500)},
      {"logs/wardmast.log", log_tail(log_path, log_bytes)}
    ]
    |> Kernel.++(extra_files(Keyword.get(opts, :extra_files, %{})))
    |> Enum.map(fn {name, content} -> {name, Redaction.redact_patterns(content)} end)
  end

  defp extra_files(files) when is_map(files) do
    for {name, content} <- files,
        is_binary(name) and is_binary(content),
        name =~ ~r/\A[A-Za-z0-9._-]{1,100}\z/,
        name not in [".", ".."],
        do: {"client/" <> name, content}
  end

  defp extra_files(_), do: []

  defp version_text do
    v = Wardmast.Server.Status.version()

    "version: #{v.version}\nsha: #{v.sha}\nbuilt_at: #{v.built_at}\nbooted_at: #{v.booted_at}\n" <>
      "otp: #{:erlang.system_info(:otp_release)}\nelixir: #{System.version()}\n"
  end

  defp doctor_text do
    "platform: " <> inspect(Wardmast.Doctor.Platform.report(), pretty: true) <> "\n"
  rescue
    e -> "doctor unavailable: #{Exception.message(e)}\n"
  end

  defp log_tail(path, max) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case :file.pread(io, max(size - max, 0), max) do
          {:ok, data} -> data
          other -> "log unreadable: #{inspect(other)}\n"
        end
      after
        File.close(io)
      end
    else
      {:error, reason} -> "log unavailable (#{path}): #{inspect(reason)}\n"
    end
  end

  defp mask(list) when is_list(list) do
    Enum.map(list, fn
      {k, v} when is_atom(k) or is_binary(k) ->
        if to_string(k) =~ @secret_key, do: {k, Redaction.placeholder()}, else: {k, mask(v)}

      other ->
        mask(other)
    end)
  end

  defp mask(map) when is_map(map) and not is_struct(map),
    do: map |> Map.to_list() |> mask() |> Map.new()

  defp mask(struct) when is_struct(struct), do: struct |> Map.from_struct() |> mask()

  defp mask(t) when is_tuple(t), do: t |> Tuple.to_list() |> mask() |> List.to_tuple()

  defp mask(v), do: v
end
