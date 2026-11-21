defmodule Wardmast.Screenshots.Capture.Safety do
  @moduledoc """
  The data-safety layers of capture that read what the app shows (`docs/design/ui-screenshot-capture.md`
  §9.4 and §9.5, bd-995svb). Captures are supposed to use fixture data only; these are the
  defence in depth for the day a repo's `.env` or a seed is not what it should be.

  ## Fixture marker probe (`probe_marker/3`)

  With `fixture_check.marker` (`%{"path" =>, "contains" =>}`), the capture step `GET`s the marker path
  right after each boot and requires a `200` whose body contains the string. The app opts in (a
  `/health` that reports `data: fixture` only when started on fixture data). A mismatch aborts
  the boot: the capture fails with `:fixture_marker_mismatch` and nothing is shot. The error names
  the path, never the body.

  ## DOM text scan (`scan/2`)

  Every shot reports the page's visible text (`innerText`) and its `alt` / `title` attributes
  (the CDP runner reads them from the page; the command-line browser's `--dump-dom` is reduced by
  `html_text/1`). `scan/2` runs these rules, in order, over all of it:

    * `secret:<kind>`: private-key headers, AWS / GCP / GitHub / Slack / Stripe-style keys, JWTs,
      `Authorization:` values, long hex runs and long mixed-case alphanumeric runs;
    * `email-domain`: an email address whose domain is not (a subdomain of) one of the repo's
      `fixture_email_domains`;
    * `deny-pattern:<n>`: the repo's own `deny_patterns` (1-based position in the list).

  A hit is `{:withheld, rule}`. **The rule name is all that ever leaves this module**: never the
  matched text, the surrounding text or the pattern's source. That is what lets the capture log,
  `capture.json`, the PR row and the reviewer's brief carry the rule without carrying the leak.
  Text past #{1_000_000} bytes is not scanned in full, so it is withheld as `scan-too-large`
  (fail closed). It does not see pixels; it is a backstop, not a redaction.
  """

  @max_text_bytes 1_000_000
  @max_marker_bytes 65_536

  @secret_rules [
    {"secret:private-key", ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----/},
    {"secret:aws-key", ~r/\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b/},
    {"secret:gcp-key", ~r/\bAIza[0-9A-Za-z_\-]{35}(?![0-9A-Za-z_-])/},
    {"secret:github-token", ~r/\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b/},
    {"secret:slack-token", ~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/},
    {"secret:stripe-key", ~r/\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/},
    {"secret:jwt", ~r/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/},
    {"secret:authorization-header",
     ~r/\bauthorization\s*:\s*(?:bearer|basic|token)?\s*[^\s]{8,}/i},
    {"secret:long-hex", ~r/(?<![0-9A-Za-z])[0-9a-fA-F]{48,}(?![0-9A-Za-z])/}
  ]

  # Candidates for a long base64/URL-safe secret; only a run that mixes upper, lower and digits
  # counts, so a long word or a slugged path does not.
  @long_token ~r/(?<![A-Za-z0-9+\/_=-])[A-Za-z0-9+\/_-]{40,}(?![A-Za-z0-9+\/_=-])/

  @email ~r/[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*)/

  @type rule :: String.t()

  @doc """
  Scan `texts` (the page's `innerText` and its `alt`/`title` values) against `config`'s rules.
  `:clean`, or `{:withheld, rule}` naming only the rule.
  """
  @spec scan(map(), [String.t()]) :: :clean | {:withheld, rule()}
  def scan(config, texts) when is_list(texts) do
    texts = Enum.filter(texts, &is_binary/1)

    if Enum.sum(Enum.map(texts, &byte_size/1)) > @max_text_bytes do
      {:withheld, "scan-too-large"}
    else
      text = Enum.map_join(texts, "\n", &String.replace_invalid/1)

      secret(text) || email(text, config.fixture_email_domains) ||
        deny(text, config.deny_patterns) || :clean
    end
  end

  defp secret(text) do
    case Enum.find(@secret_rules, fn {_name, re} -> Regex.match?(re, text) end) do
      {name, _re} -> {:withheld, name}
      nil -> if long_token?(text), do: {:withheld, "secret:long-token"}
    end
  end

  defp long_token?(text) do
    @long_token
    |> Regex.scan(text)
    |> Enum.any?(fn [run | _] ->
      String.match?(run, ~r/[A-Z]/) and String.match?(run, ~r/[a-z]/) and
        String.match?(run, ~r/[0-9]/)
    end)
  end

  defp email(text, domains) do
    fixture = Enum.map(domains || [], &String.downcase/1)

    leaked? =
      @email
      |> Regex.scan(text)
      |> Enum.any?(fn [_all, domain] -> not fixture_domain?(String.downcase(domain), fixture) end)

    if leaked?, do: {:withheld, "email-domain"}
  end

  defp fixture_domain?(domain, fixture),
    do: Enum.any?(fixture, &(domain == &1 or String.ends_with?(domain, "." <> &1)))

  defp deny(text, patterns) do
    patterns
    |> Enum.with_index(1)
    |> Enum.find_value(fn {source, n} ->
      with {:ok, re} <- Regex.compile(source),
           true <- Regex.match?(re, text) do
        {:withheld, "deny-pattern:#{n}"}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  The text a scan reads out of a page's HTML (`chromium --dump-dom`): the text content (scripts,
  styles and comments dropped, entities decoded) and every `alt` / `title` attribute value.
  """
  @spec html_text(String.t()) :: [String.t()]
  def html_text(html) when is_binary(html) do
    html = String.replace_invalid(html)

    stripped =
      html
      |> String.replace(~r/<!--.*?-->/s, " ")
      |> String.replace(~r/<(script|style)\b[^>]*>.*?<\/\1\s*>/is, " ")

    attrs =
      ~r/\b(?:alt|title)\s*=\s*(?:"([^"]*)"|'([^']*)')/i
      |> Regex.scan(stripped)
      |> Enum.map(fn [_all | groups] -> groups |> Enum.find("", &(&1 != "")) |> decode() end)

    text = stripped |> String.replace(~r/<[^>]*>/s, " ") |> decode()
    [text | attrs]
  end

  defp decode(text) do
    text
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn whole ->
      codepoint(whole, 16)
    end)
    |> String.replace(~r/&#([0-9]+);/, fn whole -> codepoint(whole, 10) end)
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end

  defp codepoint(whole, base) do
    digits = String.replace(whole, ~r/[^0-9a-fA-F]|^x/, "")

    with {n, ""} <- Integer.parse(digits, base),
         true <- n in 1..0x10FFFF and n not in 0xD800..0xDFFF do
      <<n::utf8>>
    else
      _ -> " "
    end
  end

  @doc """
  Probe `config.fixture_check.marker` on the booted app at `base_url`. `reach` is the sandbox's
  `reach/1` options for the app (Req options). `:ok` when there is no `fixture_check` or the marker
  answers `200` with a body containing the string; otherwise `{:error, reason}`, where `reason`
  names the path and the problem and never the body.
  """
  @spec probe_marker(map(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def probe_marker(
        %{fixture_check: %{"marker" => %{"path" => path, "contains" => needle}}},
        base_url,
        reach
      ) do
    url = base_url <> path

    opts =
      [retry: false, redirect: false, receive_timeout: 5_000, request_timeout: 15_000] ++
        [into: &collect/2, decode_body: false, raw: true] ++ reach

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        if String.contains?(body, needle),
          do: :ok,
          else:
            {:error,
             "fixture_check: GET #{path} did not contain the configured fixture marker, so the " <>
               "app may be running on real data"}

      {:ok, %{status: status}} ->
        {:error, "fixture_check: GET #{path} answered #{status}, not 200 with the fixture marker"}

      {:error, exception} ->
        {:error, "fixture_check: GET #{path} failed: #{Exception.message(exception)}"}
    end
  end

  def probe_marker(_config, _base_url, _reach), do: :ok

  # Bounded: an untrusted app's body is never read past a small cap, and the marker is looked for
  # in what was read.
  defp collect({:data, data}, {req, resp}) do
    body = if is_binary(resp.body), do: resp.body <> data, else: data

    if byte_size(body) >= @max_marker_bytes,
      do: {:halt, {req, %{resp | body: body}}},
      else: {:cont, {req, %{resp | body: body}}}
  end
end
