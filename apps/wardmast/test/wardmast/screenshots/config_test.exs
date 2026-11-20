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

  # bd-3glf2a: per-boot service containers bridged into the capture sandbox.
  describe "validate/2: services" do
    defp errors_s(services), do: Config.validate(Map.put(@minimal, "services", services), "s")

    @postgres %{
      "image" => "docker.io/postgis/postgis:16-3.4@sha256:" <> String.duplicate("a", 64),
      "port" => 5432,
      "env" => %{"POSTGRES_PASSWORD" => "postgres", "POSTGRES_DB" => "app"},
      "command" => ["postgres", "-c", "fsync=off"],
      "ready" => %{"cmd" => ["pg_isready", "-h", "127.0.0.1"], "timeout_seconds" => 90},
      "socket" => "/run/postgresql/.s.PGSQL.5432"
    }

    test "accepts a full service and a minimal one" do
      assert errors_s(%{"postgres" => @postgres}) == []
      assert errors_s(%{"s3" => %{"image" => "docker.io/pgsty/silo", "port" => 9000}}) == []

      assert errors_s(%{"s3" => %{"image" => "i", "port" => 9000, "ready" => %{"tcp" => true}}}) ==
               []

      assert errors_s(%{}) == []
    end

    test "refuses unknown keys, at the service and in ready" do
      assert [msg] = errors_s(%{"postgres" => Map.put(@postgres, "network", "host")})
      assert msg =~ "s.services.postgres has unknown key(s) network"

      assert [msg] =
               errors_s(%{"postgres" => put_in(@postgres, ["ready", "http"], "/health")})

      assert msg =~ "s.services.postgres.ready has unknown key(s) http"
    end

    test "image and port are required; names are short and lowercase" do
      assert [msg] = errors_s(%{"pg" => Map.delete(@postgres, "image")})
      assert msg =~ "s.services.pg.image is required"
      assert [msg] = errors_s(%{"pg" => Map.delete(@postgres, "port")})
      assert msg =~ "s.services.pg.port is required"
      assert [_] = errors_s(%{"Postgres" => @postgres})
      assert [_] = errors_s(%{"a-very-long-service-name" => @postgres})
      assert [_] = errors_s(%{"pg" => "postgres:16"})
      assert [_] = errors_s(["postgres"])
    end

    test "image must be a plain reference" do
      for image <- ["", "-v", "a b", 7] do
        assert [msg] = errors_s(%{"pg" => Map.put(@postgres, "image", image)})
        assert msg =~ "s.services.pg.image"
      end
    end

    test "port: 1024-65535, unique, and outside the app's port_range" do
      for port <- [80, 70_000, "5432", 0] do
        assert [msg] = errors_s(%{"pg" => Map.put(@postgres, "port", port)})
        assert msg =~ "s.services.pg.port"
      end

      both = %{
        "pg" => Map.delete(@postgres, "socket"),
        "pg2" => Map.delete(@postgres, "socket")
      }

      assert [msg] = errors_s(both)
      assert msg =~ "port 5432"

      assert [msg] = errors_s(%{"pg" => Map.put(@postgres, "port", 32_100)})
      assert msg =~ "port_range"

      assert [] =
               Config.validate(
                 Map.merge(@minimal, %{
                   "port_range" => "40000-40100",
                   "services" => %{"pg" => Map.put(@postgres, "port", 32_100)}
                 }),
                 "s"
               )
    end

    test "env: literal strings, no placeholders, proxies or scrubbed credentials" do
      for {k, v} <- [
            {"POSTGRES_DB", "app_{{role}}"},
            {"HTTP_PROXY", "x"},
            {"ANTHROPIC_API_KEY", "x"},
            {"bad name", "x"},
            {"N", 5}
          ] do
        assert [msg] = errors_s(%{"pg" => Map.put(@postgres, "env", %{k => v})})
        assert msg =~ "s.services.pg.env"
      end

      assert [_] = errors_s(%{"pg" => Map.put(@postgres, "env", ["A=b"])})
    end

    test "command is a list of strings" do
      assert [_] = errors_s(%{"pg" => Map.put(@postgres, "command", "postgres -c fsync=off")})
      assert [_] = errors_s(%{"pg" => Map.put(@postgres, "command", ["postgres", 5])})
      assert [] = errors_s(%{"pg" => Map.put(@postgres, "command", [])})
    end

    test "ready is exactly one of cmd or tcp, with a bounded timeout" do
      for ready <- [
            %{},
            %{"cmd" => ["pg_isready"], "tcp" => true},
            %{"cmd" => []},
            %{"cmd" => "pg_isready"},
            %{"tcp" => false},
            %{"tcp" => true, "timeout_seconds" => 0},
            %{"tcp" => true, "timeout_seconds" => 601},
            "tcp"
          ] do
        assert [msg] = errors_s(%{"pg" => Map.put(@postgres, "ready", ready)})
        assert msg =~ "s.services.pg.ready"
      end
    end

    test "socket is a short path under /run or /tmp of the sandbox, unique" do
      for socket <- [
            "relative/s",
            "/usr/lib/s",
            "/run/../etc/s",
            "/run/" <> String.duplicate("x", 120),
            "/run/a b",
            "/run/",
            7
          ] do
        assert [msg] = errors_s(%{"pg" => Map.put(@postgres, "socket", socket)})
        assert msg =~ "s.services.pg.socket"
      end

      assert [] = errors_s(%{"pg" => Map.put(@postgres, "socket", "/tmp/pg/.s.PGSQL.5432")})

      twins = %{
        "pg" => @postgres,
        "pg2" => Map.put(@postgres, "port", 5433)
      }

      assert [msg] = errors_s(twins)
      assert msg =~ "socket"
    end

    test "one service's socket may not sit inside another's" do
      nested = %{
        "pg" => Map.put(@postgres, "socket", "/run/pg"),
        "pg2" => @postgres |> Map.put("port", 5433) |> Map.put("socket", "/run/pg/s")
      }

      assert [msg] = errors_s(nested)
      assert msg =~ "/run/pg/s"
      assert msg =~ "inside"
    end

    test "validate_partial applies the same rules" do
      assert [_] =
               Config.validate_partial(
                 %{"services" => %{"pg" => Map.put(@postgres, "bogus", 1)}},
                 "s"
               )
    end
  end

  describe "validate/2: deps" do
    test "deps.mix is a boolean; unknown keys are refused" do
      assert [] = errors(%{"deps" => %{"mix" => true}})
      assert [] = errors(%{"deps" => %{"mix" => false}})
      assert [] = errors(%{"deps" => %{}})
      assert [_] = errors(%{"deps" => %{"mix" => "yes"}})
      assert [msg] = errors(%{"deps" => %{"npm" => true}})
      assert msg =~ "s.deps has unknown key(s) npm"
      assert [_] = errors(%{"deps" => true})
    end

    # bd-ur1zty: the seed (MIX_ENV=dev, an empty environment) could not compile an app whose
    # runtime.exs raises without its env.
    test "deps.mix_env and deps.env configure the seed" do
      deps = %{
        "mix" => true,
        "mix_env" => "test",
        "env" => %{"DATABASE_URL" => "ecto://127.0.0.1/x"}
      }

      assert [] = errors(%{"deps" => deps})
      assert [_] = errors(%{"deps" => %{"mix_env" => "Test Env"}})
      assert [_] = errors(%{"deps" => %{"mix_env" => ""}})
      assert [_] = errors(%{"deps" => %{"mix_env" => 5}})
      assert [_] = errors(%{"deps" => %{"env" => "FOO=1"}})
      assert [_] = errors(%{"deps" => %{"env" => %{"FOO" => 1}}})
      assert [msg] = errors(%{"deps" => %{"bogus" => 1}})
      assert msg =~ "unknown key(s) bogus"
    end

    test "deps.mix_env may not contradict the MIX_ENV the boot's env sets" do
      assert [] = errors(%{"deps" => %{"mix_env" => "test"}, "env" => %{"MIX_ENV" => "test"}})
      assert [] = errors(%{"deps" => %{"mix_env" => "test"}, "env" => %{"FOO" => "1"}})

      assert [msg] =
               errors(%{"deps" => %{"mix_env" => "dev"}, "env" => %{"MIX_ENV" => "test"}})

      assert msg =~ "s.deps.mix_env"
      assert msg =~ "test"
    end

    test "deps.env refuses what would hand the seed a secret or a host path" do
      refused = fn env -> errors(%{"deps" => %{"env" => env}}) end

      # An operator credential (scrubbed from worker environments) and a proxy rule.
      assert [msg] = refused.(%{"ANTHROPIC_API_KEY" => "x"})
      assert msg =~ "s.deps.env.ANTHROPIC_API_KEY"
      assert [_] = refused.(%{"HTTPS_PROXY" => "http://127.0.0.1:1"})
      # What the seed sets itself, or the cache manages: MIX_ENV has its own key.
      for key <- ~w(PATH HOME TMPDIR LANG MIX_ENV MIX_DEPS_PATH HEX_HOME) do
        assert [msg] = refused.(%{key => "/x"})
        assert msg =~ "s.deps.env.#{key}"
      end

      # A placeholder is the boot's: the seed has no port, scratch or checkout of that boot.
      assert [msg] = refused.(%{"DATABASE_URL" => "ecto://127.0.0.1:{{port}}/x"})
      assert msg =~ "placeholder"
      assert [_] = refused.(%{"DATABASE_URL" => "ecto://db.example.com/x"})
    end

    test "deps_seed/1: the MIX_ENV and env the seed runs with" do
      resolve = fn block ->
        assert {:ok, c} =
                 Config.resolve(
                   ws(%{"repos" => %{"app" => %{"screenshots" => Map.merge(@minimal, block)}}}),
                   "app"
                 )

        Config.deps_seed(c)
      end

      assert %{mix_env: "dev", env: []} = resolve.(%{})

      # The boot's own MIX_ENV, so the cache is compiled the way the boot uses it; its literal
      # env values come along (a strict runtime.exs needs them), its templated ones do not.
      boot = %{
        "MIX_ENV" => "test",
        "DATABASE_URL" => "ecto://127.0.0.1/capture",
        "PORT_URL" => "http://127.0.0.1:{{port}}"
      }

      assert %{mix_env: "test", env: env} = resolve.(%{"env" => boot})
      assert env == [{"DATABASE_URL", "ecto://127.0.0.1/capture"}]

      # deps.env wins over the boot's value; deps.mix_env names the env when the boot sets it
      # elsewhere (in its start_cmd).
      assert %{mix_env: "prod", env: env} =
               resolve.(%{
                 "env" => Map.delete(boot, "MIX_ENV"),
                 "deps" => %{
                   "mix" => true,
                   "mix_env" => "prod",
                   "env" => %{"DATABASE_URL" => "ecto://127.0.0.1/seed", "X" => "1"}
                 }
               })

      assert Enum.sort(env) == [{"DATABASE_URL", "ecto://127.0.0.1/seed"}, {"X", "1"}]
    end

    test "with deps.mix on, env may not set what the deps cache manages" do
      for key <- ~w(MIX_DEPS_PATH MIX_HOME HEX_HOME HEX_OFFLINE MIX_ESBUILD_PATH MIX_TAILWIND_PATH
                    ELIXIR_MAKE_CACHE_DIR RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH) do
        assert [msg] = errors(%{"deps" => %{"mix" => true}, "env" => %{key => "/x"}})
        assert msg =~ "s.env.#{key}"
        assert [] = errors(%{"env" => %{key => "/x"}})
      end
    end
  end

  describe "the operator guide's DB-backed example (docs/screenshots.md)" do
    test "validates, and resolves to two services and the deps cache" do
      doc = File.read!(Path.expand("../../../../../docs/screenshots.md", __DIR__))
      [_, after_marker] = String.split(doc, "<!-- db-backed-example", parts: 2)
      [_, json_and_rest] = String.split(after_marker, "```json\n", parts: 2)
      [json | _] = String.split(json_and_rest, "\n```", parts: 2)
      block = Jason.decode!(json)

      assert Config.validate(block, "screenshots") == []

      assert {:ok, config} =
               Config.resolve(ws(%{"repos" => %{"app" => %{"screenshots" => block}}}), "app")

      assert Enum.map(config.services, & &1.name) == ["postgres", "s3"]
      assert config.deps == %{"mix" => true}
    end
  end

  describe "resolve/2: services and deps" do
    test "default to none and off" do
      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => @minimal}}})
      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.services == []
      assert c.deps == %{"mix" => false}
    end

    test "services resolve to a sorted list with defaults filled in; maps merge by name" do
      block =
        Map.merge(@minimal, %{
          "services" => %{"s3" => %{"image" => "silo", "port" => 9000, "command" => ["silo"]}},
          "deps" => %{"mix" => true}
        })

      workspace =
        ws(%{
          "screenshots" => %{
            "services" => %{"pg" => %{"image" => "postgres:16", "port" => 5432}}
          },
          "repos" => %{"app" => %{"screenshots" => block}}
        })

      assert {:ok, c} = Config.resolve(workspace, "app")
      assert c.deps == %{"mix" => true}

      assert [
               %{
                 name: "pg",
                 image: "postgres:16",
                 port: 5432,
                 env: [],
                 command: [],
                 ready: %{kind: :tcp, timeout_seconds: 60},
                 socket: nil
               },
               %{name: "s3", image: "silo", port: 9000, command: ["silo"]}
             ] = c.services
    end

    test "env is sorted pairs and a cmd ready keeps its argv" do
      block =
        Map.put(@minimal, "services", %{
          "pg" => %{
            "image" => "postgres:16",
            "port" => 5432,
            "env" => %{"B" => "2", "A" => "1"},
            "ready" => %{"cmd" => ["pg_isready"], "timeout_seconds" => 30},
            "socket" => "/run/pg/.s.PGSQL.5432"
          }
        })

      workspace = ws(%{"repos" => %{"app" => %{"screenshots" => block}}})
      assert {:ok, %{services: [svc]}} = Config.resolve(workspace, "app")
      assert svc.env == [{"A", "1"}, {"B", "2"}]
      assert svc.ready == %{kind: :cmd, cmd: ["pg_isready"], timeout_seconds: 30}
      assert svc.socket == "/run/pg/.s.PGSQL.5432"
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
