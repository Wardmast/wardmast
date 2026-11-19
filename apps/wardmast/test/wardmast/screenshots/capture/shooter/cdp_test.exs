defmodule Wardmast.Screenshots.Capture.Shooter.CdpTest do
  # The CDP shooter (design N1). The first half needs no browser: spec building and the mapping of
  # the runner's answer, with a fake `node`. The second half drives the REAL runner (node +
  # playwright-core + Chromium) against `Wardmast.Test.CdpFixtureApp`, a login-gated app on a
  # loopback port; it is skipped when any of the three is missing here (`Cdp.available/1` says
  # which), and `ARB_REQUIRE_CDP=1` turns that skip into a failure for CI images that ship them.
  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture.Shooter.Auto
  alias Wardmast.Screenshots.Capture.Shooter.Cdp
  alias Wardmast.Screenshots.Capture.Shooter.Chromium
  alias Wardmast.Screenshots.Config
  alias Wardmast.Test.CdpFixtureApp

  @moduletag :tmp_dir

  @login %{
    "kind" => "form",
    "path" => "/login",
    "username_selector" => "#email",
    "password_selector" => "#password",
    "submit_selector" => "#go",
    "default_persona" => "admin",
    "personas" => %{
      "admin" => %{"username" => "admin@example.com", "password" => "right"},
      "viewer" => %{"username" => "viewer@example.com", "password" => "nope"}
    }
  }

  defp entry(overrides) do
    Map.merge(
      %{
        id: "home",
        path: "/home",
        before_path: nil,
        as: nil,
        seed: nil,
        viewport: "desktop",
        theme: "light",
        steps: [],
        wait_for: nil,
        target: nil,
        full_page: false,
        hide: []
      },
      overrides
    )
  end

  defp shot(dir, overrides \\ %{}) do
    {entry_overrides, rest} = Map.pop(overrides, :entry, %{})
    {login, rest} = Map.pop(rest, :login, @login)
    {theme, rest} = Map.pop(rest, :theme, %{"color_scheme" => "light"})

    Map.merge(
      %{
        role: "after",
        base_url: "http://127.0.0.1:1",
        path: "/home",
        entry: entry(entry_overrides),
        out_file: Path.join(dir, "shot.png"),
        config: struct!(Config, login: login),
        viewport: %{"width" => 800, "height" => 600, "device_scale_factor" => 1},
        theme: theme,
        timeout_s: 20,
        ctx: %{}
      },
      rest
    )
  end

  describe "selection (Auto)" do
    @plain %{config: %Config{}, theme: %{"color_scheme" => "light"}}

    defp pick(entry_overrides, rest \\ %{}) do
      Auto.shooter_for(Map.merge(%{entry: entry(entry_overrides)}, Map.merge(@plain, rest)))
    end

    test "the command-line shooter keeps what it can do" do
      assert pick(%{}) == Chromium

      assert pick(%{}, %{theme: %{"color_scheme" => "dark", "query" => %{"theme" => "dark"}}}) ==
               Chromium
    end

    test "the CDP shooter takes anything the command line cannot" do
      assert pick(%{steps: [%{"action" => "click", "selector" => "#a"}]}) == Cdp
      assert pick(%{wait_for: %{"selector" => "#a"}}) == Cdp
      assert pick(%{target: %{"selector" => "#a"}}) == Cdp
      assert pick(%{full_page: true}) == Cdp
      assert pick(%{hide: [".t"]}) == Cdp
      assert pick(%{}, %{theme: %{"local_storage" => %{"theme" => "dark"}}}) == Cdp
      assert pick(%{}, %{config: %Config{login: @login}}) == Cdp
      assert pick(%{as: "admin"}, %{config: %Config{login: @login}}) == Cdp
    end

    test "login kind none does not need it" do
      assert pick(%{}, %{config: %Config{login: %{"kind" => "none"}}}) == Chromium
    end
  end

  describe "spec building" do
    test "carries the form login for the default persona, with its success condition", %{
      tmp_dir: dir
    } do
      spec = Cdp.build_spec(shot(dir), "/usr/bin/chromium")

      assert spec["chrome"] == "/usr/bin/chromium"
      assert spec["base_url"] == "http://127.0.0.1:1"
      assert spec["viewport"]["width"] == 800

      assert %{
               "kind" => "form",
               "path" => "/login",
               "username" => "admin@example.com",
               "password" => "right",
               "persona" => "admin",
               "success" => %{"path_not" => "/login"}
             } = spec["login"]
    end

    test "the shot's own persona and the configured success win", %{tmp_dir: dir} do
      login = Map.put(@login, "success", %{"url_not_contains" => "/sign-in"})
      spec = Cdp.build_spec(shot(dir, %{login: login, entry: %{as: "viewer"}}), "/c")

      assert spec["login"]["username"] == "viewer@example.com"
      assert spec["login"]["persona"] == "viewer"
      assert spec["login"]["success"] == %{"url_not_contains" => "/sign-in"}
    end

    test "no login block when the config has none", %{tmp_dir: dir} do
      spec = Cdp.build_spec(shot(dir, %{login: %{"kind" => "none"}}), "/c")
      assert spec["login"] == nil
    end

    test "carries the shot's steps, target, full_page, hide and the theme", %{tmp_dir: dir} do
      theme = %{"color_scheme" => "dark", "local_storage" => %{"theme" => "dark"}, "query" => %{}}

      e = %{
        steps: [%{"action" => "click", "selector" => "#open"}],
        target: %{"selector" => "#panel"},
        full_page: true,
        hide: ["#stamp"],
        wait_for: %{"selector" => "#panel"}
      }

      spec = Cdp.build_spec(shot(dir, %{entry: e, theme: theme}), "/c")

      assert spec["shot"]["steps"] == [%{"action" => "click", "selector" => "#open"}]
      assert spec["shot"]["target"] == %{"selector" => "#panel"}
      assert spec["shot"]["full_page"] == true
      assert spec["shot"]["hide"] == ["#stamp"]
      assert spec["shot"]["wait_for"] == %{"selector" => "#panel"}
      assert spec["theme"]["color_scheme"] == "dark"
      assert spec["theme"]["local_storage"] == %{"theme" => "dark"}
    end
  end

  describe "refusals before any browser starts" do
    test "a login kind the runner cannot do is a clear shot error", %{tmp_dir: dir} do
      login = %{"kind" => "cmd", "cmd" => "x", "personas" => ["a"], "default_persona" => "a"}

      assert {:error, {:shot, msg}} = Cdp.shoot(shot(dir, %{login: login}))
      assert msg =~ "login.kind"
      assert msg =~ "cmd"
    end

    test "a login with no persona to use is a clear shot error", %{tmp_dir: dir} do
      login = Map.delete(@login, "default_persona")
      assert {:error, {:shot, msg}} = Cdp.shoot(shot(dir, %{login: login}))
      assert msg =~ "persona"
    end

    test "no node is a clear shot error", %{tmp_dir: dir} do
      assert {:error, {:shot, msg}} =
               Cdp.shoot(shot(dir, %{ctx: %{node: "/nonexistent/node", chrome: "/bin/sh"}}))

      assert msg =~ "node"
    end

    test "no Chromium is a clear shot error", %{tmp_dir: dir} do
      assert {:error, {:shot, msg}} =
               Cdp.shoot(shot(dir, %{ctx: %{node: "/bin/sh", chrome: "/nonexistent/chrome"}}))

      assert msg =~ "Chromium"
    end
  end

  describe "reading the runner's answer (fake node)" do
    # A "node" that ignores the runner and prints `out`, exiting with `code`.
    defp fake_node(dir, out, code) do
      path = Path.join(dir, "fake-node-#{System.unique_integer([:positive])}")
      File.write!(path, "#!/bin/sh\ncat <<'EOF'\n#{out}\nEOF\nexit #{code}\n")
      File.chmod!(path, 0o755)
      path
    end

    defp run_fake(dir, out, code \\ 0) do
      Cdp.shoot(shot(dir, %{ctx: %{node: fake_node(dir, out, code), chrome: "/bin/sh"}}))
    end

    test "ok", %{tmp_dir: dir} do
      assert :ok = run_fake(dir, ~s({"ok":true,"blocked":[]}))
    end

    test "noise before the answer is ignored; the last JSON line wins", %{tmp_dir: dir} do
      assert :ok = run_fake(dir, "chatter\n{\"x\":1}\n{\"ok\":true}")
    end

    test "an http status answer", %{tmp_dir: dir} do
      assert {:error, {:http_status, 404}} =
               run_fake(dir, ~s({"ok":false,"kind":"http_status","status":404,"reason":"x"}))

      assert {:error, {:http_status, 500}} =
               run_fake(dir, ~s({"ok":false,"kind":"http_status","status":500}))
    end

    test "a shot failure keeps the runner's reason", %{tmp_dir: dir} do
      assert {:error, {:shot, "login as \"admin\" did not succeed"}} =
               run_fake(
                 dir,
                 ~s({"ok":false,"kind":"shot","reason":"login as \\"admin\\" did not succeed"})
               )
    end

    test "no answer at all is a shot error naming the exit status and output", %{tmp_dir: dir} do
      assert {:error, {:shot, msg}} = run_fake(dir, "Segmentation fault", 139)
      assert msg =~ "139"
      assert msg =~ "Segmentation fault"
    end

    test "exit 0 with no answer is never a success", %{tmp_dir: dir} do
      assert {:error, {:shot, msg}} = run_fake(dir, "all fine, trust me", 0)
      assert msg =~ "no answer"
    end

    test "the spec file (it holds a fixture password) is removed afterwards", %{tmp_dir: dir} do
      assert :ok = run_fake(dir, ~s({"ok":true}))
      assert Path.wildcard(Path.join(dir, ".cdp-spec-*")) == []
    end
  end

  describe "the real runner against the fixture app" do
    @availability Cdp.available(%{})
    @missing if(@availability == :ok, do: nil, else: elem(@availability, 1))
    @moduletag skip: if(System.get_env("ARB_REQUIRE_CDP") == "1", do: false, else: @missing)

    setup %{tmp_dir: dir} do
      bandit = start_supervised!({Bandit, plug: CdpFixtureApp, port: 0, ip: :loopback})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, dir: dir, base: "http://127.0.0.1:#{port}"}
    end

    defp real(%{dir: dir, base: base}, overrides) do
      Cdp.shoot(shot(dir, Map.merge(%{base_url: base, ctx: %{}}, overrides)))
    end

    defp png?(dir), do: File.read!(Path.join(dir, "shot.png")) =~ "PNG"

    test "correct credentials reach the route and shoot it", ctx do
      assert :ok = real(ctx, %{})
      assert png?(ctx.dir)
    end

    test "the persona's credentials are the ones typed (a wrong password fails, never a picture)",
         ctx do
      login = put_in(@login, ["personas", "admin", "password"], "wrong")

      assert {:error, {:shot, msg}} = real(ctx, %{login: login})
      assert msg =~ "did not succeed"
      assert msg =~ "/login"
      refute File.exists?(Path.join(ctx.dir, "shot.png"))
    end

    test "an unmet success condition fails the shot with the condition in the reason", ctx do
      # The login works, but ends on /login?ok=1, which this condition rejects.
      login =
        %{@login | "path" => "/login?stay=1"}
        |> Map.put("success", %{"url_not_contains" => "/login"})

      assert {:error, {:shot, msg}} = real(ctx, %{login: login})
      assert msg =~ "did not succeed"
      assert msg =~ "url_not_contains"
      refute File.exists?(Path.join(ctx.dir, "shot.png"))
    end

    test "url_not_contains is honoured", ctx do
      ok = Map.put(@login, "success", %{"url_not_contains" => "/login"})
      assert :ok = real(ctx, %{login: ok})

      bad = Map.put(@login, "success", %{"url_not_contains" => "/home"})
      assert {:error, {:shot, _}} = real(ctx, %{login: bad})
    end

    test "a login that never leaves the login path fails under the default condition", ctx do
      login = Map.put(@login, "path", "/login?stay=1")
      assert {:error, {:shot, msg}} = real(ctx, %{login: login})
      assert msg =~ "did not succeed"
    end

    test "a success condition the sign-in page already satisfies is refused", ctx do
      login = Map.put(@login, "success", %{"url_not_contains" => "/nowhere"})
      assert {:error, {:shot, msg}} = real(ctx, %{login: login})
      assert msg =~ "cannot detect a failed login"
    end

    test "a route that bounces back to the sign-in page is not shot", ctx do
      assert {:error, {:shot, msg}} = real(ctx, %{path: "/expired", entry: %{path: "/expired"}})
      assert msg =~ "redirected to /login"
      refute File.exists?(Path.join(ctx.dir, "shot.png"))
    end

    test "a missing login field names the selector", ctx do
      login = Map.put(@login, "username_selector", "#nope")
      assert {:error, {:shot, msg}} = real(ctx, %{login: login})
      assert msg =~ "#nope"
    end

    test "404 and 500 routes map to http_status", ctx do
      assert {:error, {:http_status, 404}} = real(ctx, %{path: "/missing"})
      assert {:error, {:http_status, 500}} = real(ctx, %{path: "/boom"})
    end

    test "steps run in order and a failing step names itself", ctx do
      steps = [
        %{"action" => "click", "selector" => "#open"},
        %{"action" => "wait_for", "selector" => "#panel", "state" => "visible"}
      ]

      assert :ok = real(ctx, %{entry: %{steps: steps}})

      assert {:error, {:shot, msg}} =
               real(ctx, %{entry: %{steps: [%{"action" => "click", "selector" => "#absent"}]}})

      assert msg =~ "step 1"
      assert msg =~ "#absent"
    end

    test "wait_for, target and hide", ctx do
      steps = [%{"action" => "click", "selector" => "#open"}]

      assert :ok =
               real(ctx, %{
                 entry: %{
                   steps: steps,
                   wait_for: %{"selector" => "#panel"},
                   target: %{"selector" => "#panel"},
                   hide: ["#stamp"]
                 }
               })

      # An element shot is smaller than the 800x600 viewport.
      assert png_size(ctx.dir) |> elem(0) < 800

      assert {:error, {:shot, msg}} =
               real(ctx, %{entry: %{wait_for: %{"selector" => "#never", "timeout_ms" => 300}}})

      assert msg =~ "wait_for"
    end

    test "full_page captures the whole page, clipped to 8000 px", ctx do
      assert :ok = real(ctx, %{path: "/tall", entry: %{path: "/tall", full_page: true}})
      {w, h} = png_size(ctx.dir)
      assert w == 800
      assert h > 3000

      assert :ok = real(ctx, %{path: "/tall", entry: %{path: "/tall"}})
      assert {800, 600} = png_size(ctx.dir)
    end

    test "theme local_storage, colour scheme, UTC and en-US are applied", ctx do
      theme = %{"color_scheme" => "dark", "local_storage" => %{"theme" => "dark"}, "query" => %{}}

      assert :ok =
               real(ctx, %{
                 theme: theme,
                 entry: %{target: %{"selector" => "#theme"}}
               })

      # Pixel-compare against the same element with the light theme: they must differ in text.
      first = File.read!(Path.join(ctx.dir, "shot.png"))

      assert :ok =
               real(ctx, %{
                 theme: %{"color_scheme" => "light"},
                 entry: %{target: %{"selector" => "#theme"}}
               })

      refute File.read!(Path.join(ctx.dir, "shot.png")) == first
    end

    test "the same shot twice is byte-identical (the page shows a millisecond clock, frozen)",
         ctx do
      opts = %{entry: %{hide: []}}
      assert :ok = real(ctx, opts)
      first = File.read!(Path.join(ctx.dir, "shot.png"))
      assert :ok = real(ctx, opts)
      assert File.read!(Path.join(ctx.dir, "shot.png")) == first
    end

    test "a request to a non-loopback host is blocked, not made", ctx do
      assert :ok =
               real(ctx, %{
                 path: "/outside",
                 entry: %{path: "/outside"},
                 login: %{"kind" => "none"}
               })
    end

    test "a non-loopback base_url is refused by the runner", ctx do
      assert {:error, {:shot, msg}} = real(ctx, %{base_url: "http://203.0.113.7"})
      assert msg =~ "loopback"
    end
  end

  # width, height of the PNG written to `dir`.
  defp png_size(dir) do
    <<_sig::binary-size(16), w::32, h::32, _::binary>> = File.read!(Path.join(dir, "shot.png"))
    {w, h}
  end
end
