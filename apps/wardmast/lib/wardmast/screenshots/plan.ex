defmodule Wardmast.Screenshots.Plan do
  @moduledoc """
  The worker's screenshots manifest (`.arbiter/screenshots.json`, `version: 1`;
  design: `docs/design/ui-screenshot-capture.md` §5.2), parsed and validated against the repo's
  `Wardmast.Screenshots.Config`.

  The plan only *describes what to shoot*: paths, viewports, themes and declarative steps. It
  never carries a command, a URL host or a credential, and unknown keys are rejected at every
  level. `parse/2` expands each shot into one `entry` per `viewport x theme`, which is the unit
  the capture step boots, shoots and pairs.

  `read/2` distinguishes a file that is not there (`{:error, :missing}`) from one that does not
  validate (`{:error, {:invalid, [message]}}`), because the capture step records those as two
  different failure reasons.
  """

  alias Wardmast.Screenshots.Config

  @top_keys ~w(version skip notes shots)
  @shot_keys ~w(id title path before_path as viewports themes steps wait_for target full_page hide seed allow_redirect)
  @id ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @max_shots 20
  @max_steps 12
  @max_hide 5

  @step_keys %{
    "click" => ~w(selector),
    "hover" => ~w(selector),
    "fill" => ~w(selector value),
    "select" => ~w(selector value),
    "check" => ~w(selector),
    "uncheck" => ~w(selector),
    "press" => ~w(key selector),
    "scroll_to" => ~w(selector),
    "goto" => ~w(path),
    "wait_for" => ~w(selector text state timeout_ms),
    "wait" => ~w(ms)
  }

  defstruct skip: nil, notes: nil, shots: []

  @type entry :: %{
          id: String.t(),
          title: String.t(),
          path: String.t(),
          before_path: String.t() | nil,
          as: String.t() | nil,
          seed: String.t() | nil,
          viewport: String.t(),
          theme: String.t(),
          steps: [map()],
          wait_for: map() | nil,
          target: map() | nil,
          full_page: boolean(),
          hide: [String.t()],
          allow_redirect: boolean()
        }

  @type t :: %__MODULE__{skip: String.t() | nil, notes: String.t() | nil, shots: [entry()]}

  @doc "Read and parse the plan at `path`."
  @spec read(String.t(), Config.t()) :: {:ok, t()} | {:error, :missing | {:invalid, [String.t()]}}
  def read(path, %Config{} = config) do
    case File.read(path) do
      {:ok, body} ->
        parse(body, config)

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:invalid, ["could not read #{path}: #{:file.format_error(reason)}"]}}
    end
  end

  @doc "Parse and validate a plan document."
  @spec parse(binary(), Config.t()) :: {:ok, t()} | {:error, {:invalid, [String.t()]}}
  def parse(body, %Config{} = config) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> build(doc, config)
      {:ok, _} -> {:error, {:invalid, ["plan must be a JSON object"]}}
      {:error, _} -> {:error, {:invalid, ["plan is not valid JSON"]}}
    end
  end

  defp build(doc, config) do
    errors = top_errors(doc) ++ shot_errors(doc, config)

    case errors do
      [] -> {:ok, %__MODULE__{skip: doc["skip"], notes: doc["notes"], shots: expand(doc, config)}}
      _ -> {:error, {:invalid, errors}}
    end
  end

  # ── validation ──────────────────────────────────────────────────────────

  defp top_errors(doc) do
    unknown(doc, @top_keys, "plan") ++
      if(doc["version"] == 1, do: [], else: ["plan version must be 1"]) ++
      string_errors(doc, "skip", 280, "plan") ++
      string_errors(doc, "notes", 500, "plan") ++
      skip_or_shots(doc)
  end

  defp skip_or_shots(%{"skip" => _, "shots" => _}), do: ["plan may not carry both skip and shots"]
  defp skip_or_shots(%{"skip" => _}), do: []

  defp skip_or_shots(%{"shots" => shots})
       when is_list(shots) and shots != [] and length(shots) <= @max_shots,
       do: []

  defp skip_or_shots(%{"shots" => _}), do: ["plan shots must be a list of 1..#{@max_shots} items"]
  defp skip_or_shots(_), do: ["plan needs either skip or shots"]

  defp shot_errors(%{"shots" => shots}, config) when is_list(shots) do
    per_shot =
      shots
      |> Enum.with_index()
      |> Enum.flat_map(fn {shot, i} -> one_shot_errors(shot, "shots[#{i}]", config) end)

    ids = for %{"id" => id} <- shots, is_binary(id), do: id

    dupes =
      ids |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))

    per_shot ++
      Enum.map(dupes, &"duplicate shot id #{inspect(&1)}") ++
      image_budget(shots, config, per_shot)
  end

  defp shot_errors(_doc, _config), do: []

  defp one_shot_errors(%{} = shot, label, config) do
    unknown(shot, @shot_keys, label) ++
      id_errors(shot["id"], label) ++
      path_errors(shot["path"], "#{label}.path", true) ++
      path_errors(shot["before_path"], "#{label}.before_path", false) ++
      string_errors(shot, "title", 80, label) ++
      names(shot["viewports"], config.viewports, "#{label}.viewports") ++
      names(shot["themes"], config.themes, "#{label}.themes") ++
      steps_errors(shot["steps"], label) ++
      selector_obj(shot["wait_for"], "#{label}.wait_for") ++
      selector_obj(shot["target"], "#{label}.target") ++
      hide_errors(shot["hide"], label) ++
      bool_errors(shot["allow_redirect"], "#{label}.allow_redirect") ++
      seed_errors(shot["seed"], config, label) ++
      persona_errors(shot["as"], config, label)
  end

  defp one_shot_errors(_shot, label, _config), do: ["#{label} must be an object"]

  defp id_errors(id, label) when is_binary(id),
    do: if(Regex.match?(@id, id), do: [], else: ["#{label}.id #{inspect(id)} is not a valid id"])

  defp id_errors(_id, label), do: ["#{label}.id is required"]

  defp path_errors(nil, label, true), do: ["#{label} is required"]
  defp path_errors(nil, _label, false), do: []

  defp path_errors(path, label, _req) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") or String.starts_with?(path, "//") ->
        ["#{label} must be a path starting with a single /, with no scheme or host"]

      String.length(path) > 300 or String.match?(path, ~r/[\x00-\x1f\s]/) ->
        ["#{label} must be at most 300 chars with no whitespace or control characters"]

      true ->
        []
    end
  end

  defp path_errors(_path, label, _req), do: ["#{label} must be a string path"]

  defp string_errors(map, key, max, label) do
    case Map.fetch(map, key) do
      :error ->
        []

      {:ok, v} when is_binary(v) and v != "" ->
        if String.length(v) <= max, do: [], else: ["#{label}.#{key} is longer than #{max}"]

      {:ok, _} ->
        ["#{label}.#{key} must be a non-empty string"]
    end
  end

  defp names(nil, _known, _label), do: []

  defp names(list, known, label) when is_list(list) and list != [] and length(list) <= 4 do
    case Enum.reject(list, &Map.has_key?(known, &1)) do
      [] -> []
      bad -> ["#{label} names not in the config: #{Enum.map_join(bad, ", ", &inspect/1)}"]
    end
  end

  defp names(_v, _known, label), do: ["#{label} must be a list of 1..4 names"]

  defp steps_errors(nil, _label), do: []

  defp steps_errors(steps, label) when is_list(steps) and length(steps) <= @max_steps do
    steps
    |> Enum.with_index()
    |> Enum.flat_map(fn {s, i} -> step_errors(s, "#{label}.steps[#{i}]") end)
  end

  defp steps_errors(_steps, label), do: ["#{label}.steps must be a list of at most #{@max_steps}"]

  defp step_errors(%{"action" => action} = step, label) when is_map_key(@step_keys, action) do
    allowed = ["action" | Map.fetch!(@step_keys, action)]
    unknown(step, allowed, label)
  end

  defp step_errors(%{"action" => action}, label),
    do: ["#{label}.action #{inspect(action)} is not a step"]

  defp step_errors(_step, label), do: ["#{label} needs an action"]

  defp selector_obj(nil, _label), do: []

  defp selector_obj(%{"selector" => s} = obj, label) when is_binary(s) and s != "",
    do: unknown(obj, ~w(selector state timeout_ms), label)

  defp selector_obj(_obj, label), do: ["#{label} needs a selector"]

  defp hide_errors(nil, _label), do: []

  defp hide_errors(list, label) when is_list(list) and length(list) <= @max_hide do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: [],
      else: ["#{label}.hide must be selectors"]
  end

  defp hide_errors(_list, label),
    do: ["#{label}.hide must be a list of at most #{@max_hide} selectors"]

  defp bool_errors(nil, _label), do: []
  defp bool_errors(value, _label) when is_boolean(value), do: []
  defp bool_errors(_value, label), do: ["#{label} must be true or false"]

  defp seed_errors(nil, _config, _label), do: []

  defp seed_errors(seed, config, label),
    do:
      if(Map.has_key?(config.seeds, seed),
        do: [],
        else: ["#{label}.seed #{inspect(seed)} is not a configured seed"]
      )

  defp persona_errors(nil, _config, _label), do: []

  defp persona_errors(as, %Config{login: login}, label) do
    personas = login |> Map.get("personas", %{}) |> persona_names()
    if as in personas, do: [], else: ["#{label}.as #{inspect(as)} is not a configured persona"]
  end

  defp persona_names(%{} = p), do: Map.keys(p)
  defp persona_names(l) when is_list(l), do: l
  defp persona_names(_), do: []

  # `shots x viewports x themes x {before, after}` (design §5.2). Skipped when the shots
  # themselves are malformed so one mistake is not reported twice.
  defp image_budget(shots, config, []) do
    max = Map.get(config.limits, "max_images", 40)

    count =
      Enum.sum(
        for shot <- shots do
          length(shot["viewports"] || config.default_viewports) *
            length(shot["themes"] || config.default_themes) * 2
        end
      )

    if count > max,
      do: ["plan would produce #{count} images, more than the limit of #{max}"],
      else: []
  end

  defp image_budget(_shots, _config, _errors), do: []

  defp unknown(map, allowed, label) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] -> []
      bad -> ["#{label} has unknown keys: #{Enum.join(Enum.sort(bad), ", ")}"]
    end
  end

  # ── expansion ───────────────────────────────────────────────────────────

  defp expand(%{"shots" => shots}, config) when is_list(shots) do
    for shot <- shots,
        viewport <- shot["viewports"] || config.default_viewports,
        theme <- shot["themes"] || config.default_themes do
      %{
        id: shot["id"],
        title: shot["title"] || shot["id"],
        path: shot["path"],
        before_path: shot["before_path"],
        as: shot["as"],
        seed: shot["seed"],
        viewport: viewport,
        theme: theme,
        steps: shot["steps"] || [],
        wait_for: shot["wait_for"],
        target: shot["target"],
        full_page: shot["full_page"] == true,
        hide: shot["hide"] || [],
        allow_redirect: shot["allow_redirect"] == true
      }
    end
  end

  defp expand(_doc, _config), do: []
end
