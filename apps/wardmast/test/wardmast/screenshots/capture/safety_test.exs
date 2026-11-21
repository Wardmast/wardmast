defmodule Wardmast.Screenshots.Capture.SafetyTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.Safety
  alias Wardmast.Screenshots.Config
  alias Wardmast.Test.CaptureMarkerPlug

  @config %Config{ui_paths: ["web/**"], start_cmd: "true"}

  defp scan(texts, config \\ @config), do: Safety.scan(config, texts)

  describe "scan/2: secret shapes" do
    test "names the rule for each shape and never the text" do
      cases = [
        {"-----BEGIN RSA PRIVATE KEY-----\nabc", "secret:private-key"},
        {"key AKIAABCDEFGHIJKLMNOP here", "secret:aws-key"},
        {"token ghp_" <> String.duplicate("a1B2", 9), "secret:github-token"},
        {"xoxb-1234567890-abcdefghij", "secret:slack-token"},
        {"sk_live_" <> String.duplicate("x9", 12), "secret:stripe-key"},
        {"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk_lmn-op",
         "secret:jwt"},
        {"Authorization: Bearer abcdef123456", "secret:authorization-header"},
        {String.duplicate("deadbeef", 8), "secret:long-hex"},
        {"AIza" <> String.duplicate("Ab1_-", 7), "secret:gcp-key"}
      ]

      for {text, rule} <- cases do
        assert {:withheld, ^rule} = scan(["hello", text]), "expected #{rule} for #{text}"
      end
    end

    test "ordinary page text is clean" do
      assert :clean == scan(["Dashboard", "Welcome back, Pat Example", "Orders (12)", ""])
      assert :clean == scan([])
    end

    test "a short hex colour or commit sha is not a secret" do
      assert :clean == scan(["#ff00aa", "abc1234", "sha 0123456789abcdef"])
    end
  end

  describe "scan/2: email domains" do
    test "a fixture domain passes, any other domain is withheld" do
      assert :clean == scan(["mail pat@example.com and kim@EXAMPLE.org"])
      assert {:withheld, "email-domain"} == scan(["contact jo@acme-corp.io"])
    end

    test "a subdomain of a fixture domain passes" do
      assert :clean == scan(["pat@mail.example.com"])
    end

    test "fixture_email_domains is the repo's own list" do
      config = %{@config | fixture_email_domains: ["fixtures.test"]}
      assert :clean == scan(["a@fixtures.test"], config)
      assert {:withheld, "email-domain"} == scan(["a@example.com"], config)
    end
  end

  describe "scan/2: deny_patterns" do
    test "names the pattern by position, never its text or the match" do
      config = %{@config | deny_patterns: ["Initech", "acme-corp\\.com"]}
      assert {:withheld, "deny-pattern:2"} == scan(["see acme-corp.com"], config)
      assert {:withheld, "deny-pattern:1"} == scan(["Initech Ltd"], config)
      assert :clean == scan(["nothing here"], config)
    end
  end

  test "text past the scan cap is still scanned up to the cap, and the cap is fail-closed" do
    big = String.duplicate("a ", 600_000)
    assert {:withheld, "scan-too-large"} == scan([big])
  end

  describe "html_text/1" do
    test "returns the visible text and the alt/title attributes, not scripts or styles" do
      html = """
      <html><head><title>Page</title><style>.x{color:red}</style></head>
      <body><script>var k="shh"</script><p>Hello &amp; welcome</p>
      <img src="a.png" alt="logo of acme-corp.com" title="tt"><a title="tip">go</a></body></html>
      """

      text = Enum.join(Safety.html_text(html), "\n")
      assert text =~ "Hello & welcome"
      assert text =~ "logo of acme-corp.com"
      assert text =~ "tip"
      refute text =~ "shh"
      refute text =~ "color:red"
    end
  end

  describe "probe_marker/3" do
    setup do
      bandit = start_supervised!({Bandit, plug: CaptureMarkerPlug, port: 0, ip: :loopback})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, port: port}
    end

    defp config(marker), do: %{@config | fixture_check: %{"marker" => marker}}

    test "no fixture_check is :ok and makes no request" do
      assert :ok == Safety.probe_marker(@config, "http://127.0.0.1:1", [])
    end

    test "ok when the body contains the string", %{port: port} do
      cfg = config(%{"path" => "/health", "contains" => "data: fixture"})
      assert :ok == Safety.probe_marker(cfg, "http://127.0.0.1:#{port}", [])
    end

    test "a mismatch is an error that names the path but never the body", %{port: port} do
      cfg = config(%{"path" => "/health", "contains" => "data: nonsense"})
      assert {:error, reason} = Safety.probe_marker(cfg, "http://127.0.0.1:#{port}", [])
      assert reason =~ "/health"
      assert reason =~ "fixture_check"
      refute reason =~ "SECRET-BODY"
      refute reason =~ "data: fixture"
    end

    test "a non-200 answer or an unreachable app is an error too", %{port: port} do
      cfg = config(%{"path" => "/missing", "contains" => "x"})
      assert {:error, _} = Safety.probe_marker(cfg, "http://127.0.0.1:#{port}", [])
      assert {:error, _} = Safety.probe_marker(cfg, "http://127.0.0.1:1", [])
    end
  end
end
