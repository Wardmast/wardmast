defmodule Wardmast.Mergers.ForgeCli do
  @moduledoc """
  Forge-specific wording and conventions for worker/reviewer prompts: which CLI
  checks out / views a PR or MR, where its description template lives, and how
  a GitLab job trace is addressed. GitHub is the default; only a repo whose
  effective merge strategy is `gitlab` gets the GitLab variants.
  """

  alias Wardmast.Mergers
  alias Wardmast.Tasks.Workspace

  @type forge :: :github | :gitlab

  @doc "The forge of `repo` in `workspace`; `:github` when unknown or not GitLab."
  @spec forge(Workspace.t() | nil, String.t() | nil) :: forge()
  def forge(%Workspace{} = workspace, repo) do
    if Mergers.strategy(workspace, repo) == :gitlab, do: :gitlab, else: :github
  rescue
    _ -> :github
  end

  def forge(_workspace, _repo), do: :github

  @doc "The forge a merger ref implies: `group/proj!42` / `!42` is GitLab, else GitHub."
  @spec forge_from_ref(term()) :: forge()
  def forge_from_ref(ref) when is_binary(ref) do
    if String.contains?(ref, "!") and not String.contains?(ref, "#"), do: :gitlab, else: :github
  end

  def forge_from_ref(_), do: :github

  @doc "The numeric PR number / MR iid of a ref (`#42`, `owner/repo#42`, `!42`, `g/p!42`)."
  @spec ref_number(term()) :: pos_integer() | nil
  def ref_number(ref) when is_binary(ref) do
    case ref |> String.split(["#", "!"]) |> List.last() |> Integer.parse() do
      {int, ""} -> int
      _ -> nil
    end
  end

  def ref_number(_), do: nil

  @doc "`:github` → `gh pr`, `:gitlab` → `glab mr`."
  @spec cli(forge()) :: String.t()
  def cli(:gitlab), do: "glab mr"
  def cli(_), do: "gh pr"

  @doc "The forge's own name for a change request."
  @spec noun(forge()) :: String.t()
  def noun(:gitlab), do: "merge request"
  def noun(_), do: "pull request"

  @doc "Command that checks out the branch of change request `ref`."
  @spec checkout_cmd(forge(), term()) :: String.t()
  def checkout_cmd(forge, ref), do: "#{cli(forge)} checkout #{ref_arg(forge, ref)}"

  @doc "Command that views change request `ref`."
  @spec view_cmd(forge(), term()) :: String.t()
  def view_cmd(forge, ref), do: "#{cli(forge)} view #{ref_arg(forge, ref)}"

  @doc "Command that reads the existing reviews/comments of change request `ref`."
  @spec reviews_cmd(forge(), term()) :: String.t()
  def reviews_cmd(:gitlab, ref), do: "glab mr view #{ref_arg(:gitlab, ref)} --comments"
  def reviews_cmd(forge, ref), do: view_cmd(forge, ref) <> " --json reviews,reviewComments"

  @doc "Repo-relative description-template location(s), as prompt text."
  @spec template_hint(forge()) :: String.t()
  def template_hint(:gitlab),
    do:
      "`.gitlab/merge_request_templates/Default.md` (or another `.gitlab/merge_request_templates/*.md`)"

  def template_hint(_), do: "`.github/pull_request_template.md`"

  @doc "Raw trace URL of a GitLab job from its `web_url`."
  @spec job_trace_url(String.t() | nil) :: String.t() | nil
  def job_trace_url(url) when is_binary(url) and url != "" do
    if String.ends_with?(url, "/raw"), do: url, else: String.trim_trailing(url, "/") <> "/raw"
  end

  def job_trace_url(_), do: nil

  # GitHub keeps the ref as given. `glab` wants the bare iid, not `!42` or
  # `group/proj!42`.
  defp ref_arg(:gitlab, ref), do: to_string(ref_number(ref) || ref)
  defp ref_arg(_forge, ref), do: to_string(ref)
end
