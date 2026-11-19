defmodule Wardmast.Screenshots.ConfigTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Config

  defp ws(worker), do: %{config: %{"worker" => worker}}

  @minimal %{"ui_paths" => ["lib/*_web/**/*.heex"], "start_cmd" => "mix phx.server"}

  describe "resolve/2" do
    test "off (:none) when nothing is configured" do
      assert Config.resolve(nil, "app") == :none
      assert Config.resolve(%{config: %{}}, "app") == :none
      assert Config.resolve(ws(%{"preview" => %{"command" => "x"}}), "app") == :none
    end

    test "off when enabled is false" do
      workspace =
        ws(%{"repos" => %{"app" => %{"screenshots" => Map.put(@minimal, "enabled", false)}}})

      assert Config.resolve(workspace, "app") == :none
    end

    test "fills the design defaults" do
      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => @minimal}}})
      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.ui_paths == ["lib/*_web/**/*.heex"]
      assert c.ignore_paths == []
      assert c.plan_required == true
      assert c.base_url == "http://127.0.0.1:{{port}}"
      assert c.port_env == "PORT"
      assert c.port_range == {32_000, 32_999}
      assert c.login == %{"kind" => "none"}
      assert Map.keys(c.viewports) |> Enum.sort() == ["desktop", "mobile"]
      assert c.default_viewports == ["desktop"]
      assert c.default_themes == ["light"]
      assert c.ready == %{"path" => "/", "timeout_seconds" => 120, "expect" => "below_500"}
      assert c.limits["budget_seconds"] == 1200
      assert c.attach == true
      assert c.hosting["public_repo_ok"] == false
    end

    test "another repo does not see a per-repo block" do
      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => @minimal}}})
      assert Config.resolve(workspace, "other") == :none
    end

    test "repo keys win over the workspace block; maps merge by key" do
      workspace =
        ws(%{
          "screenshots" =>
            Map.merge(@minimal, %{
              "env" => %{"A" => "1", "B" => "2"},
              "viewports" => %{"wide" => %{"width" => 1920, "height" => 1080}},
              "limits" => %{"max_shots" => 5}
            }),
          "repos" => %{
            "app" => %{
              "screenshots" => %{
                "start_cmd" => "bin/dev",
                "env" => %{"B" => "3"},
                "limits" => %{"shot_seconds" => 10}
              }
            }
          }
        })

      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.start_cmd == "bin/dev"
      assert c.env == %{"A" => "1", "B" => "3"}
      assert Map.has_key?(c.viewports, "wide")
      assert c.limits["max_shots"] == 5
      assert c.limits["shot_seconds"] == 10
      assert {:ok, %{start_cmd: "mix phx.server"}} = Config.resolve(workspace, "other")
    end

    test "start_cmd, setup_cmd and ready inherit from preview" do
      workspace =
        ws(%{
          "preview" => %{
            "command" => "bin/dev",
            "setup" => "mix deps.get",
            "ready_path" => "/up",
            "ready_timeout" => 45
          },
          "repos" => %{"app" => %{"screenshots" => %{"ui_paths" => ["assets/**"]}}}
        })

      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.start_cmd == "bin/dev"
      assert c.setup_cmd == "mix deps.get"
      assert c.ready["path"] == "/up"
      assert c.ready["timeout_seconds"] == 45
    end

    test "explicit screenshots keys beat preview" do
      workspace =
        ws(%{
          "preview" => %{"command" => "bin/dev"},
          "repos" => %{"app" => %{"screenshots" => @minimal}}
        })

      assert {:ok, %{start_cmd: "mix phx.server"}} = Config.resolve(workspace, "app")
    end

    test "an invalid block is an error list, never a silent default" do
      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => %{"start_cmd" => "x"}}}})
      assert {:error, [msg | _]} = Config.resolve(workspace, "app")
      assert msg =~ "ui_paths"
    end
  end

  describe "validate/2" do
    defp errors(overrides), do: Config.validate(Map.merge(@minimal, overrides), "s")

    test "accepts the minimal block and the design's full example" do
      assert Config.validate(@minimal, "s") == []

      full =
        Map.merge(@minimal, %{
          "enabled" => true,
          "ignore_paths" => ["**/*.md"],
          "default_routes" => ["/"],
          "setup_cmd" => "mix deps.get",
          "seed_cmd" => "mix run seeds.exs",
          "seeds" => %{"empty" => "mix run e.exs"},
          "port_env" => "PORT",
          "port_range" => "32000-32999",
          "base_url" => "http://localhost:{{port}}",
          "env" => %{"DATABASE_PATH" => "{{scratch}}/{{role}}.sqlite3", "PHX_HOST" => "127.0.0.1"},
          "ready" => %{"path" => "/", "timeout_seconds" => 180, "expect" => "2xx"},
          "login" => %{
            "kind" => "form",
            "default_persona" => "admin",
            "path" => "/login",
            "username_selector" => "#email",
            "password_selector" => "#password",
            "submit_selector" => "button",
            "success" => %{"path_not" => "/login", "url_not_contains" => "/sign-in"},
            "personas" => %{"admin" => %{"username" => "a@example.com", "password" => "pw"}}
          },
          "viewports" => %{
            "tablet" => %{"width" => 800, "height" => 600, "device_scale_factor" => 2}
          },
          "default_viewports" => ["tablet"],
          "themes" => %{
            "dark" => %{"color_scheme" => "dark", "local_storage" => %{"theme" => "dark"}}
          },
          "default_themes" => ["dark"],
          "fixture_check" => %{"marker" => %{"path" => "/health", "contains" => "fixture"}},
          "deny_patterns" => ["acme-corp\\.com"],
          "fixture_email_domains" => ["example.com"],
          "limits" => %{
            "max_shots" => 20,
            "memory" => "4g",
            "cpus" => 2,
            "budget_seconds" => 1200
          },
          "hosting" => %{
            "github" => %{"mode" => "assets_branch", "branch" => "arbiter-assets"},
            "public_repo_ok" => false,
            "retention_days" => 90
          },
          "attach" => true
        })

      assert Config.validate(full, "s") == []
    end

    test "refuses unknown keys and non-maps" do
      assert [msg] = errors(%{"bogus" => 1})
      assert msg =~ "unknown key"
      assert Config.validate("x", "s") == ["s must be a map"]
    end

    test "ui_paths must be a non-empty list of non-empty globs" do
      assert [_] = Config.validate(%{"start_cmd" => "x"}, "s")
      assert [_] = errors(%{"ui_paths" => []})
      assert [_] = errors(%{"ui_paths" => [""]})
      assert [_] = errors(%{"ui_paths" => ["/abs/**"]})
      assert [_] = errors(%{"ui_paths" => ["../x/**"]})
    end

    test "start_cmd is required unless preview supplies it (resolve inherits)" do
      assert [msg] = Config.validate(%{"ui_paths" => ["a/**"]}, "s")
      assert msg =~ "start_cmd"
    end

    test "unknown placeholders are refused; {{persona}} only in login.cmd" do
      assert [m] = errors(%{"start_cmd" => "run {{nope}}"})
      assert m =~ "nope"
      assert [_] = errors(%{"start_cmd" => "run {{persona}}"})

      assert [] =
               errors(%{
                 "login" => %{"kind" => "cmd", "cmd" => "x {{persona}}", "personas" => ["a"]}
               })
    end

    test "base_url host must be loopback" do
      assert [] = errors(%{"base_url" => "http://127.0.0.1:{{port}}"})
      assert [_] = errors(%{"base_url" => "http://example.com:{{port}}"})
      assert [_] = errors(%{"base_url" => "not a url"})
    end

    test "env refuses proxies, scrubbed keys and non-loopback URLs" do
      assert [_] = errors(%{"env" => %{"HTTP_PROXY" => "x"}})
      assert [_] = errors(%{"env" => %{"no_proxy" => "x"}})
      assert [_] = errors(%{"env" => %{"ANTHROPIC_API_KEY" => "x"}})
      assert [_] = errors(%{"env" => %{"API" => "https://evil.example.com/x"}})
      assert [_] = errors(%{"env" => %{"API" => "evil.example.com:8080"}})
      assert [] = errors(%{"env" => %{"API" => "http://127.0.0.1:4000"}})
    end

    test "viewport, limit and range bounds" do
      assert [_] = errors(%{"viewports" => %{"Bad Name" => %{"width" => 300, "height" => 300}}})
      assert [_] = errors(%{"viewports" => %{"a" => %{"width" => 100, "height" => 300}}})
      assert [_] = errors(%{"viewports" => %{"a" => %{"width" => 300, "height" => 5000}}})

      assert [_] =
               errors(%{
                 "viewports" => %{
                   "a" => %{"width" => 300, "height" => 300, "device_scale_factor" => 4}
                 }
               })

      assert [_] = errors(%{"limits" => %{"budget_seconds" => 4000}})
      assert [_] = errors(%{"limits" => %{"memory" => "32g"}})
      assert [_] = errors(%{"limits" => %{"max_shots" => 0}})
      assert [_] = errors(%{"limits" => %{"max_captures_per_ticket" => 0}})
      assert [_] = errors(%{"port_range" => "20000-20100"})
      assert [_] = errors(%{"default_viewports" => ["nope"]})
    end

    test "merge_wait_seconds is gone from the schema (bd-8qj1sa) but a stored value stays valid" do
      refute Map.has_key?(%Config{}.limits, "merge_wait_seconds")
      assert errors(%{"limits" => %{"merge_wait_seconds" => 900}}) == []
      assert [_] = errors(%{"limits" => %{"merge_wait_seconds" => 0}})
      assert [_] = errors(%{"limits" => %{"bogus_limit" => 1}})
    end

    test "login kinds" do
      assert [_] = errors(%{"login" => %{"kind" => "magic"}})
      assert [_ | _] = errors(%{"login" => %{"kind" => "cmd"}})
      assert [_ | _] = errors(%{"login" => %{"kind" => "form"}})
    end

    @form_login %{
      "kind" => "form",
      "path" => "/login",
      "username_selector" => "#u",
      "password_selector" => "#p",
      "submit_selector" => "#go",
      "personas" => %{"admin" => %{"username" => "a", "password" => "b"}}
    }

    test "login.success accepts path_not and url_not_contains" do
      for success <- [
            %{"path_not" => "/login"},
            %{"url_not_contains" => "/sign-in"},
            %{"path_not" => "/login", "url_not_contains" => "error"}
          ] do
        assert errors(%{"login" => Map.put(@form_login, "success", success)}) == []
      end

      assert errors(%{"login" => @form_login}) == []
    end

    test "login.success refuses unknown shapes" do
      for success <- [
            %{"selector" => "#nav"},
            %{},
            %{"path_not" => "login"},
            %{"path_not" => ""},
            %{"url_not_contains" => 5},
            %{"path_not" => "/login", "extra" => "x"},
            "/login"
          ] do
        assert [msg] = errors(%{"login" => Map.put(@form_login, "success", success)})
        assert msg =~ "login.success"
      end
    end

    test "login_success/1 defaults to leaving the login path" do
      assert Config.login_success(%{"path" => "/login"}) == %{"path_not" => "/login"}

      assert Config.login_success(%{"path" => "/login?next=/"}) == %{"path_not" => "/login"}

      assert Config.login_success(%{"path" => "/l", "success" => %{"url_not_contains" => "x"}}) ==
               %{"url_not_contains" => "x"}
    end

    test "sandbox.readonly_paths takes absolute or ~/ paths, never / or the whole home" do
      ok = %{"sandbox" => %{"readonly_paths" => ["~/.asdf", "/opt/erlang", "~/.mix"]}}
      assert [] = errors(ok)
      assert [] = errors(%{"sandbox" => %{}})

      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => ["relative/dir"]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => ["/"]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => ["/usr/.."]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => ["~"]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => ["~/"]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => [System.user_home!()]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => [""]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => [7]}})
      assert [_] = errors(%{"sandbox" => %{"readonly_paths" => "/opt"}})
      assert [_] = errors(%{"sandbox" => %{"writable_paths" => ["/opt"]}})
      assert [_] = errors(%{"sandbox" => "bwrap"})
    end
  end

  describe "resolve/2: sandbox" do
    test "defaults to no extra read-only paths" do
      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => @minimal}}})
      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.sandbox == %{"readonly_paths" => []}
    end

    test "carries the operator's read-only paths through" do
      block = Map.put(@minimal, "sandbox", %{"readonly_paths" => ["~/.asdf"]})
      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => block}}})
      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.sandbox == %{"readonly_paths" => ["~/.asdf"]}
    end
  end

  describe "touches_ui_paths?/2" do
    setup do
      workspace =
        ws(%{
          "repos" => %{
            "app" => %{
              "screenshots" =>
                Map.merge(@minimal, %{
                  "ui_paths" => ["lib/*_web/**/*.heex", "assets/**"],
                  "ignore_paths" => ["**/*.md", "assets/vendor/**"]
                })
            }
          }
        })

      {:ok, config} = Config.resolve(workspace, "app")
      %{config: config}
    end

    test "a match", %{config: c} do
      assert Config.touches_ui_paths?(c, ["README.txt", "lib/app_web/live/x.html.heex"])
      assert Config.touches_ui_paths?(c, ["assets/css/app.css"])
    end

    test "no match", %{config: c} do
      refute Config.touches_ui_paths?(c, ["lib/app/accounts.ex", "mix.exs"])
      refute Config.touches_ui_paths?(c, [])
    end

    test "ignored paths do not count", %{config: c} do
      refute Config.touches_ui_paths?(c, ["assets/README.md", "assets/vendor/x.js"])
      assert Config.touches_ui_paths?(c, ["assets/README.md", "assets/js/app.js"])
    end

    test "matches_ui_path?/2 on one file", %{config: c} do
      assert Config.matches_ui_path?(c, "assets/js/app.js")
      refute Config.matches_ui_path?(c, "assets/vendor/a.js")
    end
  end
end
