defmodule Wardmast.Attachments do
  @moduledoc """
  Image attachments on a ticket (bd-5hlegn; limits and retention from
  `docs/design/ui-screenshot-capture.md` §10).

  ## Storage

  Bytes on disk, content-addressed:
  `<root>/<workspace_id>/<sha256[0:2]>/<sha256>.<ext>`, with the metadata and
  provenance in `ticket_attachments` (`Wardmast.Attachments.Attachment`). The same
  bytes attached twice within a workspace share one blob. The root is
  `config :wardmast, :attachments, root: …`, default `<data home>/attachments`.

  ## Limits (`limits/0`, overridable under `config :wardmast, :attachments`)

  | Limit | Default |
  |---|---|
  | image types | `png`, `webp`, `jpg`, sniffed from the bytes |
  | per image | 2 MiB, 3840 px wide, 8000 px tall |
  | per ticket | 100 MiB, 200 files |
  | global | 5 GiB; at the limit, **closed** tickets' blobs are pruned oldest first, open tickets' never |

  The per-capture caps (40 images, 24 MiB) belong to the capture pass, which
  rejects a capture whole; they are not re-checked here.

  ## Retention

    * **Open ticket:** kept.
    * **Closed ticket:** `prune_expired/1` deletes the blob 90 days after
      `closed_at`; the row stays with `pruned_at`, its hash and provenance, so
      the ticket still says "had 6 screenshots, pruned".
    * **Hard-deleted ticket:** the rows go with it, and so do blobs no other row
      references. The app never destroys a ticket (its paper-trail history
      references it, so `Ash.destroy` fails), so this covers a delete done out
      of band: `sweep_orphans/0` finds rows whose ticket is gone and calls
      `purge_task/1`, and the retention sweeper (`Wardmast.Attachments.Retention`)
      runs both sweeps.

  ## Who may write what

  `create/3` is what the API and MCP call: `source` is `"worker"`,
  `"coordinator"` or `"operator"`, derived from the caller's tier and never from
  the request. `"arbiter-capture"` is refused there and written only by
  `create_capture/2`, which makes the source a guarantee that an image came from
  a capture and was not supplied by a worker.
  """

  import Ecto.Query

  alias Wardmast.Attachments.Attachment
  alias Wardmast.Attachments.Image
  alias Wardmast.Repo
  alias Wardmast.Tasks.Issue

  require Logger

  @manual_sources ~w(worker coordinator operator)
  @capture_source "arbiter-capture"
  @roles ~w(before after)

  @defaults %{
    max_image_bytes: 2 * 1024 * 1024,
    max_width: 3840,
    max_height: 8000,
    max_ticket_bytes: 100 * 1024 * 1024,
    max_ticket_files: 200,
    max_total_bytes: 5 * 1024 * 1024 * 1024,
    retention_days: 90
  }

  @type error :: {:invalid | :conflict | :forbidden, String.t()} | {atom(), String.t(), map()}

  @doc "The effective limits: the design's defaults overlaid with app config."
  @spec limits() :: %{atom() => pos_integer()}
  def limits do
    overrides = config() |> Keyword.take(Map.keys(@defaults)) |> Map.new()
    Map.merge(@defaults, overrides)
  end

  @doc "The sources a hand attach may carry (the capture source is not one of them)."
  @spec manual_sources() :: [String.t()]
  def manual_sources, do: @manual_sources

  @doc "The directory every blob lives under."
  @spec root() :: String.t()
  def root do
    case Keyword.get(config(), :root) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(Wardmast.Nodes.Agent.data_home(), "attachments")
    end
  end

  # --- create ---------------------------------------------------------------

  @doc """
  Attach an image to `issue` by hand. `attrs` takes `:data` (the raw bytes) and
  optionally `:filename`, `:caption`, `:role` (`"before"`/`"after"`), `:shot_id`
  (the key that pairs a before with its after), `:viewport` and `:theme`. The
  `source:` option is required and must be `"worker"`, `"coordinator"` or
  `"operator"`.
  """
  @spec create(Issue.t(), map(), keyword()) :: {:ok, Attachment.t()} | {:error, error()}
  def create(%Issue{} = issue, attrs, opts) do
    case Keyword.fetch(opts, :source) do
      {:ok, source} when source in @manual_sources ->
        store(issue, attrs, source, manual_fields())

      {:ok, @capture_source} ->
        {:error,
         {:forbidden, "the #{@capture_source} source is written only by the capture pass"}}

      _ ->
        {:error, {:invalid, "source must be one of #{Enum.join(@manual_sources, ", ")}"}}
    end
  end

  @doc """
  Attach a captured screenshot, with its provenance (`:capture_id`, `:head_sha`,
  `:base_sha`, `:shot_id`, `:viewport`, `:theme`, `:role`). Arbiter-internal: the
  only writer of the `"arbiter-capture"` source.
  """
  @spec create_capture(Issue.t(), map()) :: {:ok, Attachment.t()} | {:error, error()}
  def create_capture(%Issue{} = issue, attrs),
    do: store(issue, attrs, @capture_source, manual_fields() ++ ~w(capture_id head_sha base_sha)a)

  @doc """
  Decode a base64 `data` argument (standard or URL-safe alphabet, padded or
  not). Refuses before decoding what could not fit under the per-image limit, so
  a huge string is not inflated into memory first.
  """
  @spec decode_base64(term()) :: {:ok, binary()} | {:error, error()}
  def decode_base64(data) when is_binary(data) do
    max = limits().max_image_bytes
    # base64 is 4 chars per 3 bytes; allow slack for line breaks / padding.
    cond do
      byte_size(data) > div(max * 4, 3) + 1024 ->
        {:error, too_large(max)}

      true ->
        cleaned = String.replace(data, ~r/\s+/, "")

        with :error <- Base.decode64(cleaned, padding: false),
             :error <- Base.url_decode64(cleaned, padding: false) do
          {:error, {:invalid, "data is not valid base64", %{reason: "bad_base64"}}}
        end
    end
  end

  def decode_base64(_), do: {:error, {:invalid, "data (base64 image bytes) is required"}}

  defp manual_fields, do: ~w(filename caption role shot_id viewport theme)a

  defp store(%Issue{} = issue, attrs, source, allowed) do
    attrs = Map.take(attrs, [:data | allowed])

    with {:ok, data} <- fetch_data(attrs),
         {:ok, info} <- check_image(data),
         {:ok, fields} <- clean_fields(Map.delete(attrs, :data)),
         :ok <- check_room(issue, byte_size(data)) do
      sha = Base.encode16(:crypto.hash(:sha256, data), case: :lower)

      row =
        fields
        |> Map.merge(%{
          task_id: issue.id,
          workspace_id: issue.workspace_id,
          content_type: info.type,
          byte_size: byte_size(data),
          width: info.width,
          height: info.height,
          sha256: sha,
          source: source
        })

      write_and_insert(row, info.ext, data)
    end
  end

  defp fetch_data(%{data: data}) when is_binary(data) and data != "", do: {:ok, data}
  defp fetch_data(_), do: {:error, {:invalid, "data (the image bytes) is required"}}

  defp check_image(data) do
    %{max_image_bytes: max, max_width: max_w, max_height: max_h} = limits()

    if byte_size(data) > max do
      {:error, too_large(max)}
    else
      case Image.inspect_binary(data) do
        {:ok, %{width: w, height: h}} when w > max_w or h > max_h ->
          {:error,
           {:invalid, "image is #{w}x#{h}px; the limit is #{max_w}x#{max_h}px",
            %{reason: "dimensions", limit_width: max_w, limit_height: max_h}}}

        {:ok, info} ->
          {:ok, info}

        {:error, :unsupported_type} ->
          {:error,
           {:invalid, "only png, webp and jpg images can be attached",
            %{reason: "unsupported_type"}}}

        {:error, :corrupt} ->
          {:error, {:invalid, "the image header is truncated or corrupt", %{reason: "corrupt"}}}
      end
    end
  end

  defp too_large(max),
    do:
      {:invalid, "image exceeds the #{max}-byte per-image limit",
       %{reason: "too_large", limit: max}}

  @field_rules %{
    filename: {:text, 120},
    caption: {:text, 500},
    role: {:enum, @roles},
    shot_id: {:regex, ~r/^[a-z0-9][a-z0-9-]{0,62}$/},
    viewport: {:regex, ~r/^[a-z0-9-]{1,20}$/},
    theme: {:regex, ~r/^[a-z0-9-]{1,20}$/},
    capture_id: {:text, 80},
    head_sha: {:text, 64},
    base_sha: {:text, 64}
  }

  defp clean_fields(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case clean_field(key, value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, cleaned} -> {:cont, {:ok, Map.put(acc, key, cleaned)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp clean_field(_key, nil), do: {:ok, nil}

  defp clean_field(key, value) do
    case {Map.fetch!(@field_rules, key), value} do
      {{:text, max}, v} when is_binary(v) -> text(key, v, max)
      {{:enum, allowed}, v} when is_binary(v) -> enum(key, v, allowed)
      {{:regex, re}, v} when is_binary(v) -> regex(key, v, re)
      _ -> {:error, {:invalid, "#{key} must be a string"}}
    end
  end

  defp text(:filename, value, max) do
    # A name for display only — never part of a path. Strip any directory part.
    base = value |> String.replace("\\", "/") |> Path.basename()
    text(:caption, base, max)
  end

  defp text(key, value, max) do
    cleaned = value |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, "") |> String.trim()

    cond do
      not String.valid?(cleaned) ->
        {:error, {:invalid, "#{key} must be valid UTF-8"}}

      String.length(cleaned) > max ->
        {:error, {:invalid, "#{key} is longer than #{max} characters"}}

      cleaned == "" ->
        {:ok, nil}

      true ->
        {:ok, cleaned}
    end
  end

  defp enum(key, value, allowed) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid, "#{key} must be one of #{Enum.join(allowed, ", ")}"}}
  end

  defp regex(key, value, re) do
    if Regex.match?(re, value),
      do: {:ok, value},
      else: {:error, {:invalid, "#{key} #{inspect(value)} is not a valid #{key} key"}}
  end

  # Per-ticket and global ceilings. The global one makes room by pruning closed
  # tickets' blobs, oldest first; an open ticket's attachment is never touched.
  defp check_room(issue, incoming) do
    limits = limits()
    {files, bytes} = ticket_usage(issue.id)

    cond do
      files + 1 > limits.max_ticket_files ->
        {:error,
         {:conflict,
          "ticket already holds #{files} attachments (limit #{limits.max_ticket_files})",
          %{reason: "ticket_file_limit", limit: limits.max_ticket_files}}}

      bytes + incoming > limits.max_ticket_bytes ->
        {:error,
         {:conflict,
          "ticket attachments would exceed #{limits.max_ticket_bytes} bytes (holds #{bytes})",
          %{reason: "ticket_byte_limit", limit: limits.max_ticket_bytes}}}

      true ->
        make_room(incoming, limits.max_total_bytes)
    end
  end

  defp make_room(incoming, max_total) do
    if stored_bytes() + incoming <= max_total do
      :ok
    else
      prune_oldest_closed_until(incoming, max_total)

      if stored_bytes() + incoming <= max_total,
        do: :ok,
        else:
          {:error,
           {:conflict,
            "the attachment store is at its #{max_total}-byte limit and nothing closed is left to prune",
            %{reason: "global_limit", limit: max_total}}}
    end
  end

  defp prune_oldest_closed_until(incoming, max_total) do
    Attachment
    |> join(:inner, [a], i in "issues", on: i.id == a.task_id)
    |> where([a, i], i.state == "closed" and is_nil(a.pruned_at))
    |> order_by([a, i], asc: i.closed_at, asc: a.inserted_at)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn row, :ok ->
      prune_row(row)
      if stored_bytes() + incoming <= max_total, do: {:halt, :ok}, else: {:cont, :ok}
    end)
  end

  defp write_and_insert(row, ext, data) do
    path = blob_path(row.workspace_id, row.sha256, ext)

    with :ok <- write_blob(path, data) do
      case Repo.insert(struct(Attachment, row)) do
        {:ok, att} ->
          {:ok, att}

        {:error, reason} ->
          Logger.error("attachment insert failed: #{inspect(reason)}")
          remove_blob_if_unreferenced(row.workspace_id, row.sha256, ext)
          {:error, {:invalid, "could not record the attachment"}}
      end
    end
  end

  defp write_blob(path, data) do
    if File.exists?(path) do
      :ok
    else
      tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, data),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(tmp)
          Logger.error("attachment blob write failed: #{inspect(reason)}")
          {:error, {:invalid, "could not store the attachment"}}
      end
    end
  end

  # --- read -----------------------------------------------------------------

  @doc "A ticket's attachments, oldest first."
  @spec list(String.t()) :: [Attachment.t()]
  def list(task_id) do
    Attachment
    |> where([a], a.task_id == ^task_id)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> Repo.all()
  end

  @doc "One attachment by id, or `nil`."
  @spec get(String.t()) :: Attachment.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Attachment, uuid)
      :error -> nil
    end
  end

  @doc "The stored bytes, or `{:error, :pruned | :missing}`."
  @spec read_blob(Attachment.t()) :: {:ok, binary()} | {:error, :pruned | :missing}
  def read_blob(%Attachment{pruned_at: %DateTime{}}), do: {:error, :pruned}

  def read_blob(%Attachment{} = att) do
    case File.read(path_for(att)) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :missing}
    end
  end

  @doc """
  Group a ticket's attachments for display: a `before` and an `after` that share
  `shot_id`, `viewport` and `theme` become one `%{kind: :pair, before:, after:}`;
  everything else is `%{kind: :single, attachment:}`. Order follows the first
  member of each group.
  """
  @spec pairs([Attachment.t()]) :: [map()]
  def pairs(attachments) do
    by_key =
      attachments
      |> Enum.filter(&(&1.shot_id && &1.role in @roles))
      |> Enum.group_by(&pair_key/1)

    {items, _seen} =
      Enum.reduce(attachments, {[], MapSet.new()}, fn att, {acc, seen} ->
        key = pair_key(att)
        pair = paired(by_key, att, key)

        cond do
          pair == nil -> {[%{kind: :single, attachment: att} | acc], seen}
          MapSet.member?(seen, key) -> {acc, seen}
          true -> {[pair | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(items)
  end

  defp pair_key(%{shot_id: nil}), do: nil
  defp pair_key(a), do: {a.shot_id, a.viewport, a.theme}

  defp paired(by_key, att, key) when not is_nil(key) do
    members = Map.get(by_key, key, [])
    before_att = members |> Enum.filter(&(&1.role == "before")) |> List.last()
    after_att = members |> Enum.filter(&(&1.role == "after")) |> List.last()

    if (att.role in @roles and before_att) && after_att,
      do: %{kind: :pair, before: before_att, after: after_att, key: key},
      else: nil
  end

  defp paired(_, _, _), do: nil

  @doc "The JSON shape of an attachment: metadata and a dashboard URL, never bytes."
  @spec serialize(Attachment.t()) :: map()
  def serialize(%Attachment{} = a) do
    %{
      id: a.id,
      task_id: a.task_id,
      workspace_id: a.workspace_id,
      filename: a.filename,
      caption: a.caption,
      content_type: a.content_type,
      byte_size: a.byte_size,
      width: a.width,
      height: a.height,
      sha256: a.sha256,
      source: a.source,
      role: a.role,
      shot_id: a.shot_id,
      viewport: a.viewport,
      theme: a.theme,
      capture_id: a.capture_id,
      head_sha: a.head_sha,
      base_sha: a.base_sha,
      pruned: not is_nil(a.pruned_at),
      pruned_at: a.pruned_at,
      url: if(a.pruned_at, do: nil, else: "/attachments/#{a.id}"),
      created_at: a.inserted_at
    }
  end

  # --- upstream mirror seam ---------------------------------------------------

  @doc """
  Mirror an attachment to the ticket's upstream tracker, where the tracker
  supports files (`Wardmast.Trackers.upload_attachment/2`). A **seam**: it is not
  called on attach, and no adapter implements the upload yet, so today it is
  `{:error, :not_supported}`; a per-tracker follow-up adds the adapter callback
  and a caller. A pruned attachment has no bytes to send (`{:error, :pruned}`).
  """
  @spec mirror(Issue.t(), Attachment.t()) :: :ok | {:error, :not_supported | :pruned | term()}
  def mirror(%Issue{} = issue, %Attachment{} = att) do
    with {:ok, data} <- read_blob(att) do
      Wardmast.Trackers.upload_attachment(issue, %{
        filename: att.filename || "#{att.sha256}.#{ext_of(att)}",
        content_type: att.content_type,
        data: data
      })
    else
      {:error, :missing} -> {:error, :pruned}
      {:error, _} = error -> error
    end
  end

  # --- retention ------------------------------------------------------------

  @doc """
  Delete the attachments of a hard-deleted ticket: the rows, and every blob no
  other row still references. Called from the ticket's destroy action.
  """
  @spec purge_task(String.t()) :: :ok
  def purge_task(task_id) do
    rows = Repo.all(from a in Attachment, where: a.task_id == ^task_id)
    Repo.delete_all(from a in Attachment, where: a.task_id == ^task_id)

    rows
    |> Enum.uniq_by(&{&1.workspace_id, &1.sha256})
    |> Enum.each(&remove_blob_if_unreferenced(&1.workspace_id, &1.sha256, ext_of(&1)))
  end

  @doc """
  The retention sweep: delete the blob of every attachment on a ticket that was
  closed more than `retention_days` (90) ago. The row stays, with `pruned_at`.
  Options: `:now` (a `DateTime`, for tests), `:retention_days`. Returns
  `%{pruned: count}`; idempotent.
  """
  @spec prune_expired(keyword()) :: %{pruned: non_neg_integer()}
  def prune_expired(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    days = Keyword.get(opts, :retention_days, limits().retention_days)
    cutoff = DateTime.add(now, -days * 86_400)

    pruned =
      Attachment
      |> join(:inner, [a], i in "issues", on: i.id == a.task_id)
      |> where(
        [a, i],
        i.state == "closed" and not is_nil(i.closed_at) and is_nil(a.pruned_at) and
          i.closed_at < type(^cutoff, :utc_datetime_usec)
      )
      |> Repo.all()
      |> Enum.map(&prune_row/1)
      |> Enum.count(&(&1 == :ok))

    %{pruned: pruned}
  end

  @doc """
  Collect the attachments of tickets that no longer exist. Tickets are not
  deleted through the app (their paper-trail history references them), so this
  is the safety net for a hard delete done out of band: it finds attachment rows
  whose ticket is gone and `purge_task/1`s each. Returns `%{purged: tickets}`;
  idempotent.
  """
  @spec sweep_orphans() :: %{purged: non_neg_integer()}
  def sweep_orphans do
    orphans =
      Repo.all(
        from a in Attachment,
          left_join: i in "issues",
          on: i.id == a.task_id,
          where: is_nil(i.id),
          distinct: true,
          select: a.task_id
      )

    Enum.each(orphans, &purge_task/1)
    %{purged: length(orphans)}
  end

  # Mark one row pruned and delete its blob unless another live row shares it.
  defp prune_row(%Attachment{} = row) do
    {1, _} =
      Repo.update_all(from(a in Attachment, where: a.id == ^row.id),
        set: [pruned_at: DateTime.utc_now()]
      )

    remove_blob_if_unreferenced(row.workspace_id, row.sha256, ext_of(row))
    :ok
  end

  defp remove_blob_if_unreferenced(workspace_id, sha, ext) do
    live? =
      Repo.exists?(
        from a in Attachment,
          where: a.workspace_id == ^workspace_id and a.sha256 == ^sha and is_nil(a.pruned_at)
      )

    unless live?, do: _ = File.rm(blob_path(workspace_id, sha, ext))
    :ok
  end

  # --- sizes ----------------------------------------------------------------

  defp ticket_usage(task_id) do
    {files, bytes} =
      Repo.one(
        from a in Attachment,
          where: a.task_id == ^task_id and is_nil(a.pruned_at),
          select: {count(a.id), coalesce(sum(a.byte_size), 0)}
      )

    {files, bytes}
  end

  # Bytes on disk: a blob shared by several rows counts once.
  defp stored_bytes do
    unique =
      from a in Attachment,
        where: is_nil(a.pruned_at),
        group_by: [a.workspace_id, a.sha256],
        select: %{size: max(a.byte_size)}

    Repo.one(from u in subquery(unique), select: coalesce(sum(u.size), 0))
  end

  # --- paths ----------------------------------------------------------------

  defp path_for(%Attachment{} = a), do: blob_path(a.workspace_id, a.sha256, ext_of(a))

  defp blob_path(workspace_id, sha, ext),
    do: Path.join([root(), workspace_id, String.slice(sha, 0, 2), "#{sha}.#{ext}"])

  defp ext_of(%Attachment{content_type: "image/png"}), do: "png"
  defp ext_of(%Attachment{content_type: "image/webp"}), do: "webp"
  defp ext_of(%Attachment{content_type: "image/jpeg"}), do: "jpg"

  defp config, do: Application.get_env(:wardmast, :attachments, [])
end
