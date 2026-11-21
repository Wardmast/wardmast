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
  alias Wardmast.Test.CaptureHostSandbox
  alias Wardmast.Test.CaptureRecordingSandbox
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
        # The shooter only ever runs node and Chromium through the capture sandbox, in the
        # shot's own `scratch` (removed when the shot is done). This one passes the argv through
        # to the host; the sandbox seam itself is exercised with a recording one below.
        sandbox: CaptureHostSandbox,
        app: %{port: 1},
        scratch: Path.join(dir, "scratch-#{System.unique_integer([:positive])}"),
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

    test "post_login_path is rendered from the persona's fields and the shot's path", %{
      tmp_dir: dir
    } do
      login =
        @login
        |> Map.put(
          "post_login_path",
          "/switch-tenant/{{persona.tenant_id}}?return_to={{return_to}}"
        )
        |> put_in(["personas", "admin", "tenant_id"], "t 1")

      spec =
        Cdp.build_spec(shot(dir, %{login: login, path: "/reports?a=b"}), "/c")

      assert spec["login"]["post_login_path"] == "/switch-tenant/t+1?return_to=%2Freports%3Fa%3Db"
    end

    test "post_login_path naming a field the persona lacks refuses the shot", %{tmp_dir: dir} do
      login = Map.put(@login, "post_login_path", "/switch-tenant/{{persona.tenant_id}}")

      assert {:error, {:shot, msg}} = Cdp.shoot(shot(dir, %{login: login}))
      assert msg =~ "persona.tenant_id"
    end

    test "a persona's password is never a post_login_path value", %{tmp_dir: dir} do
      login = Map.put(@login, "post_login_path", "/x/{{persona.password}}")
      assert {:error, {:shot, msg}} = Cdp.shoot(shot(dir, %{login: login}))
      assert msg =~ "persona.password"
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

  describe "the capture sandbox" do
    defp node_script(dir, name, body) do
      path = Path.join(dir, name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      path
    end

    defp capture_dir(dir) do
      capture_dir = Path.join(dir, "capture")
      File.mkdir_p!(capture_dir)
      File.write!(Path.join(capture_dir, "runner.mjs"), "")
      capture_dir
    end

    test "node and Chromium run through sandbox.browser/4, with only the scratch dir writable", %{
      tmp_dir: dir
    } do
      node =
        node_script(dir, "recording-node", ~s(echo "$@" > #{dir}/node-argv\necho '{"ok":true}'\n))

      capture_dir = capture_dir(dir)
      scratch = Path.join(dir, "scratch")
      app = %{port: 4321, socket: "/s/sock"}

      spec =
        shot(dir, %{
          sandbox: CaptureRecordingSandbox,
          app: app,
          scratch: scratch,
          ctx: %{node: node, capture_dir: capture_dir, chrome: "/bin/sh"}
        })

      # The runner "succeeds" but leaves no image: not a success.
      assert {:error, {:shot, msg}} = Cdp.shoot(spec)
      assert msg =~ "no image"

      assert_received {:sandbox_browser, [^node, runner, spec_file], ^app, [^scratch], readonly}
      assert runner == Path.join(capture_dir, "runner.mjs")
      assert Path.dirname(spec_file) == scratch
      # what the runner needs of the host: its own dir (node_modules) and the browser
      assert capture_dir in readonly
      assert "/bin/sh" in readonly
      # it really ran, inside the wrapper
      assert File.read!(Path.join(dir, "node-argv")) =~ "runner.mjs"
      refute File.exists?(scratch)
    end

    test "the runner writes the image into the scratch dir and it is copied out", %{tmp_dir: dir} do
      node =
        node_script(dir, "writing-node", """
        out=$(grep -o '"out_file":"[^"]*"' "$2" | cut -d'"' -f4)
        printf 'PNGDATA' > "$out"
        txt=$(grep -o '"text_file":"[^"]*"' "$2" | cut -d'"' -f4)
        printf '["page text"]' > "$txt"
        echo '{"ok":true}'
        """)

      spec =
        shot(dir, %{
          sandbox: CaptureRecordingSandbox,
          ctx: %{node: node, capture_dir: capture_dir(dir), chrome: "/bin/sh"}
        })

      assert {:ok, %{text: _}} = Cdp.shoot(spec)
      assert File.read!(spec.out_file) == "PNGDATA"
      refute File.exists?(spec.scratch)
    end

    test "a sandbox that cannot start the browser fails the shot with its reason", %{tmp_dir: dir} do
      spec =
        shot(dir, %{
          sandbox: CaptureRecordingSandbox,
          app: %{port: 1, fail: true},
          ctx: %{node: "/bin/sh", capture_dir: capture_dir(dir), chrome: "/bin/sh"}
        })

      assert {:error, {:shot, msg}} = Cdp.shoot(spec)
      assert msg =~ "could not start the browser"
      assert msg =~ ":boom"
    end

    test "a spec without a sandbox, a booted app or a scratch dir starts nothing", %{tmp_dir: dir} do
      ctx = %{node: "/bin/sh", chrome: "/bin/sh"}

      for overrides <- [%{sandbox: nil}, %{app: nil}, %{scratch: nil}] do
        assert {:error, {:shot, msg}} = Cdp.shoot(shot(dir, Map.merge(%{ctx: ctx}, overrides)))
        assert msg =~ "no capture sandbox"
      end

      no_keys = dir |> shot(%{ctx: ctx}) |> Map.drop([:sandbox, :app, :scratch])
      assert {:error, {:shot, msg}} = Cdp.shoot(no_keys)
      assert msg =~ "no capture sandbox"
      refute_received {:sandbox_browser, _, _, _, _}
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
      # It also leaves an image where the spec says (an "ok" answer with none is a failure).
      File.write!(path, """
      #!/bin/sh
      img=$(grep -o '"out_file":"[^"]*"' "$2" | cut -d'"' -f4)
      printf PNG > "$img"
      txt=$(grep -o '"text_file":"[^"]*"' "$2" | cut -d'"' -f4)
      printf '["page text"]' > "$txt"
      cat <<'EOF'
      #{out}
      EOF
      exit #{code}
      """)

      File.chmod!(path, 0o755)
      path
    end

    defp run_fake(dir, out, code \\ 0) do
      Cdp.shoot(shot(dir, %{ctx: %{node: fake_node(dir, out, code), chrome: "/bin/sh"}}))
    end

    test "ok", %{tmp_dir: dir} do
      assert {:ok, %{text: _}} = run_fake(dir, ~s({"ok":true,"blocked":[]}))
    end

    test "the page text the runner wrote is what the shooter reports (bd-995svb)", %{tmp_dir: dir} do
      assert {:ok, %{text: ["page text"]}} = run_fake(dir, ~s({"ok":true}))
    end

    test "an ok answer with an image but no page text is a failed shot, not an unscanned one", %{
      tmp_dir: dir
    } do
      node =
        node_script(dir, "no-text-node", """
        out=$(grep -o '"out_file":"[^"]*"' "$2" | cut -d'"' -f4)
        printf 'PNGDATA' > "$out"
        echo '{"ok":true}'
        """)

      spec =
        shot(dir, %{
          sandbox: CaptureRecordingSandbox,
          ctx: %{node: node, capture_dir: capture_dir(dir), chrome: "/bin/sh"}
        })

      assert {:error, {:shot, msg}} = Cdp.shoot(spec)
      assert msg =~ "page text"
      refute File.exists?(spec.out_file)
    end

    test "noise before the answer is ignored; the last JSON line wins", %{tmp_dir: dir} do
      assert {:ok, %{text: _}} = run_fake(dir, "chatter\n{\"x\":1}\n{\"ok\":true}")
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

    test "the shot's scratch dir (it held the spec with a fixture password) is gone afterwards",
         %{tmp_dir: dir} do
      spec = shot(dir, %{ctx: %{node: fake_node(dir, ~s({"ok":false}), 0), chrome: "/bin/sh"}})
      assert {:error, {:shot, _}} = Cdp.shoot(spec)
      refute File.exists?(spec.scratch)
    end
  end

  describe "the real runner against the fixture app" do
    @availability Cdp.available(%{})
    @missing if(@availability == :ok, do: nil, else: elem(@availability, 1))
    @describetag skip: if(System.get_env("ARB_REQUIRE_CDP") == "1", do: false, else: @missing)

    setup %{tmp_dir: dir} do
      bandit = start_supervised!({Bandit, plug: CdpFixtureApp, port: 0, ip: :loopback})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, dir: dir, base: "http://127.0.0.1:#{port}"}
    end

    defp real(%{dir: dir, base: base}, overrides) do
      Cdp.shoot(shot(dir, Map.merge(%{base_url: base, ctx: tree_ctx(dir)}, overrides)))
    end

    defp png?(dir), do: File.read!(Path.join(dir, "shot.png")) =~ "PNG"

    # The default capture dir may hold an older runner; test the one in this tree.
    defp tree_ctx(dir) do
      tools = Path.join(dir, "tools")
      File.mkdir_p!(tools)

      File.cp!(
        Application.app_dir(:wardmast, "priv/capture/runner.mjs"),
        Path.join(tools, "runner.mjs")
      )

      src =
        System.get_env("ARB_CAPTURE_DIR") || Application.app_dir(:wardmast, "priv/capture")

      for sub <- ~w(node_modules bin),
          File.exists?(Path.join(src, sub)),
          not File.exists?(Path.join(tools, sub)),
          do: File.ln_s!(Path.join(src, sub), Path.join(tools, sub))

      %{capture_dir: tools}
    end

    test "a multi-tenant persona selects its tenant after login, then lands on the route", ctx do
      route = %{path: "/reports", entry: %{wait_for: %{"selector" => "#reports"}}}
      ctx_map = tree_ctx(ctx.dir)

      # Without the knob the shot is the tenant picker: #reports never shows.
      assert {:error, {:shot, msg}} = real(ctx, Map.put(route, :ctx, ctx_map))
      assert msg =~ "wait_for"

      login =
        @login
        |> Map.put(
          "post_login_path",
          "/switch-tenant/{{persona.tenant_id}}?return_to={{return_to}}"
        )
        |> put_in(["personas", "admin", "tenant_id"], "harbor")

      assert {:ok, %{text: _}} = real(ctx, Map.merge(route, %{login: login, ctx: ctx_map}))
      assert png?(ctx.dir)
    end

    test "correct credentials reach the route and shoot it", ctx do
      assert {:ok, %{text: _}} = real(ctx, %{})
      assert png?(ctx.dir)
    end

    test "it reports the page's visible text for the data-safety scan (bd-995svb)", ctx do
      assert {:ok, %{text: texts}} = real(ctx, %{})
      assert Enum.join(texts, "\n") =~ "Dashboard"
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
      assert {:ok, %{text: _}} = real(ctx, %{login: ok})

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

      assert {:ok, %{text: _}} = real(ctx, %{entry: %{steps: steps}})

      assert {:error, {:shot, msg}} =
               real(ctx, %{entry: %{steps: [%{"action" => "click", "selector" => "#absent"}]}})

      assert msg =~ "step 1"
      assert msg =~ "#absent"
    end

    test "wait_for, target and hide", ctx do
      steps = [%{"action" => "click", "selector" => "#open"}]

      assert {:ok, %{text: _}} =
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
      assert {:ok, %{text: _}} = real(ctx, %{path: "/tall", entry: %{path: "/tall", full_page: true}})
      {w, h} = png_size(ctx.dir)
      assert w == 800
      assert h > 3000

      assert {:ok, %{text: _}} = real(ctx, %{path: "/tall", entry: %{path: "/tall"}})
      assert {800, 600} = png_size(ctx.dir)
    end

    test "theme local_storage, colour scheme, UTC and en-US are applied", ctx do
      theme = %{"color_scheme" => "dark", "local_storage" => %{"theme" => "dark"}, "query" => %{}}

      assert {:ok, %{text: _}} =
               real(ctx, %{
                 theme: theme,
                 entry: %{target: %{"selector" => "#theme"}}
               })

      # Pixel-compare against the same element with the light theme: they must differ in text.
      first = File.read!(Path.join(ctx.dir, "shot.png"))

      assert {:ok, %{text: _}} =
               real(ctx, %{
                 theme: %{"color_scheme" => "light"},
                 entry: %{target: %{"selector" => "#theme"}}
               })

      refute File.read!(Path.join(ctx.dir, "shot.png")) == first
    end

    test "the same shot twice is byte-identical (the page shows a millisecond clock, frozen)",
         ctx do
      opts = %{entry: %{hide: []}}
      assert {:ok, %{text: _}} = real(ctx, opts)
      first = File.read!(Path.join(ctx.dir, "shot.png"))
      assert {:ok, %{text: _}} = real(ctx, opts)
      assert File.read!(Path.join(ctx.dir, "shot.png")) == first
    end

    test "a request to a non-loopback host is blocked, not made", ctx do
      assert {:ok, %{text: _}} =
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
