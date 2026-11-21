defmodule Wardmast.Worker.Image.PublishLedger do
  @moduledoc """
  Which repos published a run image, and when (SI2, `docs/design/remote-workers.md`
  §21.9): the `Wardmast.Worker.CliSet.Watcher` republishes the ones that published
  in the last 14 days when the CLI set moves.

  One entry per repo (`{repo, repo_path}`), holding the publish context
  (`Image.Publisher.ensure_ready/2`'s `ctx`, plan included) of the newest
  successful publish and its time. It lives in a file under the image root so a
  restart does not forget it; the Publisher only records into it when its
  `:ledger` option, or `config :wardmast, :image_publisher, ledger: path`, names a
  file (default `<image root>/publish-ledger.term`; the test suite sets it to
  `nil`).
  """

  require Logger

  alias Wardmast.Config.Paths

  @type entry :: %{key: term(), ctx: map(), at: DateTime.t(), ref: String.t() | nil}

  @doc "The ledger file, or `nil` when recording is off."
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []) do
    case Keyword.fetch(opts, :ledger) do
      {:ok, path} ->
        path

      :error ->
        :wardmast
        |> Application.get_env(:image_publisher, [])
        |> Keyword.get_lazy(:ledger, fn ->
          Path.join(Paths.image_root(), "publish-ledger.term")
        end)
    end
  end

  @doc "Note that `ctx`'s repo published just now. A no-op while the ledger is off."
  @spec record(map(), keyword()) :: :ok
  def record(ctx, opts \\ []) do
    case path(opts) do
      nil ->
        :ok

      file ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        key = {Map.get(ctx, :repo), Map.get(ctx, :repo_path)}
        touch? = Keyword.get(opts, :touch, true)

        :global.trans({{__MODULE__, file}, self()}, fn ->
          entries = read(file)

          at =
            case {touch?, Map.get(entries, key)} do
              {false, %{at: existing_at}} -> existing_at
              _ -> now
            end

          entry = %{
            key: key,
            ctx: plain_ctx(ctx),
            at: at,
            ref: Keyword.get(opts, :ref),
            image: Keyword.get(opts, :image)
          }

          write(file, Map.put(entries, key, entry))
        end)

        :ok
    end
  end

  @doc "The entries recorded within the last `days` days, newest first."
  @spec recent(non_neg_integer(), keyword()) :: [entry()]
  def recent(days, opts \\ []) do
    case path(opts) do
      nil ->
        []

      file ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        cutoff = DateTime.add(now, -days * 86_400, :second)

        file
        |> read()
        |> Map.values()
        |> Enum.filter(&(DateTime.compare(&1.at, cutoff) != :lt))
        |> Enum.sort_by(& &1.at, {:desc, DateTime})
    end
  end

  @doc """
  SI7: the digest-pinned ref `repo`'s newest successful publish produced, or `nil` (never
  published, a publish before refs were recorded, or the ledger off). What warm-first
  placement looks for in a node's `hb.images`.
  """
  @spec last_ref(String.t() | nil, keyword()) :: String.t() | nil
  def last_ref(repo, opts \\ [])

  def last_ref(repo, opts) when is_binary(repo) do
    case path(opts) do
      nil ->
        nil

      file ->
        file
        |> read()
        |> Map.values()
        |> Enum.filter(&(elem(&1.key, 0) == repo and is_binary(Map.get(&1, :ref))))
        |> Enum.max_by(& &1.at, DateTime, fn -> nil end)
        |> case do
          nil -> nil
          entry -> entry.ref
        end
    end
  end

  def last_ref(_repo, _opts), do: nil

  @doc """
  Like `last_ref/2`, but says why there is no ref: `{:ok, ref}`, `:never_published` (the
  ledger has nothing for the repo), `{:error, :no_ref_recorded}` (the repo has entries from
  before digests were kept) or `{:error, {:ledger_unreadable, reason}}` (the file exists but
  cannot be decoded, which is NOT the same as "never published").
  """
  @spec lookup(String.t() | nil, keyword()) ::
          {:ok, String.t()} | :never_published | {:error, term()}
  def lookup(repo, opts \\ [])

  def lookup(repo, opts) when is_binary(repo) do
    with file when is_binary(file) <- path(opts),
         {:ok, entries} <- read_status(file) do
      mine = entries |> Map.values() |> Enum.filter(&(elem(&1.key, 0) == repo))

      case last_ref(repo, opts) do
        ref when is_binary(ref) -> {:ok, ref}
        _ when mine == [] -> :never_published
        _ -> {:error, :no_ref_recorded}
      end
    else
      nil -> :never_published
      {:error, reason} -> {:error, {:ledger_unreadable, reason}}
    end
  end

  def lookup(_repo, _opts), do: :never_published

  @doc """
  SI11: per repo, its newest publish as the doctor's `image <repo>` row shows it:
  `%{repo, ref, at, providers, clis, seed}` (the last three are `nil` for a publish
  recorded before they were kept). `[]` while the ledger is off.
  """
  @spec images(keyword()) :: [map()]
  def images(opts \\ []) do
    case path(opts) do
      nil ->
        []

      file ->
        file
        |> read()
        |> Map.values()
        |> Enum.filter(&(is_binary(elem(&1.key, 0)) and is_binary(Map.get(&1, :ref))))
        |> Enum.group_by(&elem(&1.key, 0))
        |> Enum.map(fn {_repo, entries} -> Enum.max_by(entries, & &1.at, DateTime) end)
        |> Enum.sort_by(&elem(&1.key, 0))
        |> Enum.map(fn entry ->
          image = Map.get(entry, :image) || %{}

          %{
            repo: elem(entry.key, 0),
            ref: entry.ref,
            at: entry.at,
            providers: Map.get(image, :providers),
            clis: Map.get(image, :clis),
            seed: Map.get(image, :seed)
          }
        end)
    end
  end

  defp read(file) do
    case read_status(file) do
      {:ok, entries} -> entries
      {:error, reason} -> warn_unreadable(file, reason)
    end
  end

  defp read_status(file) do
    case File.read(file) do
      {:ok, bin} -> decode(bin)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(bin) do
    case safe_decode(bin) do
      %{} = entries ->
        {:ok, clean(entries)}

      _ ->
        # An entry written before the Arbiter -> Wardmast rename names `Arbiter.*`
        # modules, atoms that no longer exist, so the safe decode refuses it. Rewrite
        # those atoms to their current names and try once more.
        with rewritten when rewritten != bin <- rewrite_legacy_atoms(bin),
             %{} = entries <- safe_decode(rewritten) do
          {:ok, clean(entries)}
        else
          _ -> {:error, :undecodable}
        end
    end
  end

  defp warn_unreadable(file, reason) do
    Logger.warning(
      "publish ledger #{file} could not be read (#{inspect(reason)}); treating it as empty"
    )

    %{}
  end

  # Drop what cannot be a ledger entry, and swap any module struct in an entry's ctx for
  # plain data (a legacy entry's `:workspace` becomes its `:workspace_id`).
  defp clean(entries) do
    entries
    |> Enum.flat_map(fn
      {key, %{at: %DateTime{}, ctx: ctx} = entry} when is_map(ctx) ->
        [{key, %{entry | ctx: plain_ctx(ctx)}}]

      {key, _} ->
        Logger.warning("publish ledger: skipping unreadable entry #{inspect(key)}")
        []
    end)
    |> Map.new()
  end

  @doc false
  # The ctx as stored: no module structs. The workspace is kept as its id and re-read at
  # use time (`Watcher`), so a renamed or reshaped schema cannot strand the entry.
  @spec plain_ctx(map()) :: map()
  def plain_ctx(ctx) do
    {workspace, ctx} = Map.pop(ctx, :workspace)

    ctx =
      case workspace_id(workspace) do
        nil -> ctx
        id -> Map.put_new(ctx, :workspace_id, id)
      end

    plain(ctx)
  end

  defp workspace_id(%{id: id}) when is_binary(id), do: id
  defp workspace_id(_), do: nil

  defp plain(%_{} = struct) do
    case struct do
      %DateTime{} -> struct
      %NaiveDateTime{} -> struct
      %Date{} -> struct
      %Time{} -> struct
      _ -> struct |> Map.from_struct() |> plain()
    end
  end

  defp plain(%{} = map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)

  defp plain(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> plain() |> List.to_tuple()

  defp plain(other), do: other

  # Rewrite each `Elixir.Arbiter[Web].…` atom in the external term format to its
  # `Wardmast` name (`Wardmast.LegacyModuleName`), fixing the atom's length prefix.
  # ATOM_UTF8_EXT is `118, len::16`; SMALL_ATOM_UTF8_EXT is `119, len::8`.
  defp rewrite_legacy_atoms(bin) do
    ~r/(?:\x76([\x00-\xff]{2})|\x77([\x00-\xff]))Elixir\.Arbiter(?:Web)?\./s
    |> Regex.scan(bin, return: :index)
    |> Enum.reverse()
    |> Enum.reduce(bin, fn [{start, _len} | _], acc -> rewrite_atom_at(acc, start) end)
  end

  defp rewrite_atom_at(bin, start) do
    {tag, name_start, len} =
      case binary_part(bin, start, 3) do
        <<118, l::16>> -> {118, start + 3, l}
        <<119, l::8, _>> -> {119, start + 2, l}
      end

    if name_start + len <= byte_size(bin) do
      name = binary_part(bin, name_start, len)
      new = Wardmast.LegacyModuleName.normalize(name)
      head = binary_part(bin, 0, start)
      tail = binary_part(bin, name_start + len, byte_size(bin) - name_start - len)
      new_len = byte_size(new)

      if new_len < 256 and tag == 119,
        do: <<head::binary, 119, new_len::8, new::binary, tail::binary>>,
        else: <<head::binary, 118, new_len::16, new::binary, tail::binary>>
    else
      bin
    end
  end

  # The ledger is this host's own file, written only by `write/2`, never user input, so
  # atom exhaustion is not a concern. `:safe` alone refuses any atom the VM has not
  # loaded yet (a ctx key from a module not touched since boot), which made a fresh
  # server read a valid ledger as empty ("never_published"). Try `:safe` first, then the
  # plain decode for exactly that case.
  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> trusted_decode(bin)
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp trusted_decode(bin) do
    :erlang.binary_to_term(bin)
  rescue
    ArgumentError -> nil
  end

  defp write(file, entries) do
    File.mkdir_p!(Path.dirname(file))
    tmp = file <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, :erlang.term_to_binary(entries))
    File.rename!(tmp, file)
  end
end
