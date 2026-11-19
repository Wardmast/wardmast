defmodule Wardmast.Config.PathsTest do
  use ExUnit.Case, async: false

  alias Wardmast.Config.Paths

  # async: false — we mutate both process env and the :wardmast application
  # env for :worktree_root / :output_log_root.

  setup do
    prior_env_wt = Wardmast.Env.get("WARDMAST_WORKTREE_ROOT")
    prior_env_log = Wardmast.Env.get("WARDMAST_OUTPUT_LOG_ROOT")
    prior_cfg_wt = Application.get_env(:wardmast, :worktree_root)
    prior_cfg_log = Application.get_env(:wardmast, :output_log_root)
    prior_env_sess = Wardmast.Env.get("WARDMAST_COORDINATOR_SESSION_DIRS")
    prior_cfg_sess = Application.get_env(:wardmast, :coordinator_session_dirs)

    on_exit(fn ->
      restore_env("WARDMAST_WORKTREE_ROOT", prior_env_wt)
      restore_env("WARDMAST_OUTPUT_LOG_ROOT", prior_env_log)
      restore_env("WARDMAST_COORDINATOR_SESSION_DIRS", prior_env_sess)
      restore_cfg(:worktree_root, prior_cfg_wt)
      restore_cfg(:output_log_root, prior_cfg_log)
      restore_cfg(:coordinator_session_dirs, prior_cfg_sess)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp restore_cfg(key, nil), do: Application.delete_env(:wardmast, key)
  defp restore_cfg(key, val), do: Application.put_env(:wardmast, key, val)

  describe "explicit_primary_checkout/0 (bd-6dpdwm)" do
    setup do
      home = Path.join(System.tmp_dir!(), "paths_home_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)

      prior =
        for k <- ["HOME", "WARDMAST_PRIMARY_CHECKOUT", "ARB_HOME"], do: {k, System.get_env(k)}

      prior_cfg = Application.get_env(:wardmast, :primary_checkout)

      System.put_env("HOME", home)
      System.delete_env("WARDMAST_PRIMARY_CHECKOUT")
      System.delete_env("ARB_HOME")
      Application.delete_env(:wardmast, :primary_checkout)

      on_exit(fn ->
        Enum.each(prior, fn {k, v} -> restore_env(k, v) end)
        restore_cfg(:primary_checkout, prior_cfg)
        File.rm_rf(home)
      end)

      %{home: home}
    end

    test "is nil when nothing is configured, though primary_checkout/0 still guesses", %{
      home: home
    } do
      assert Paths.explicit_primary_checkout() == nil
      assert Paths.primary_checkout() == Path.join(home, "dev/arbiter")
    end

    test "returns the env override" do
      System.put_env("WARDMAST_PRIMARY_CHECKOUT", "/srv/example/env")
      assert Paths.explicit_primary_checkout() == "/srv/example/env"
    end

    test "returns application config" do
      Application.put_env(:wardmast, :primary_checkout, "/srv/example/cfg")
      assert Paths.explicit_primary_checkout() == "/srv/example/cfg"
    end

    test "returns the install-service recorded home", %{home: home} do
      File.mkdir_p!(Path.join(home, ".config/wardmast"))
      File.write!(Path.join(home, ".config/wardmast/home"), "/srv/example/recorded\n")
      assert Paths.explicit_primary_checkout() == "/srv/example/recorded"
    end

    test "agrees with primary_checkout/0 whenever something is explicit" do
      Application.put_env(:wardmast, :primary_checkout, "/srv/example/cfg")
      assert Paths.explicit_primary_checkout() == Paths.primary_checkout()
    end
  end

  describe "worktree_root/0" do
    test "env var wins over app config and default" do
      System.put_env("WARDMAST_WORKTREE_ROOT", "/tmp/from-env-wt")
      Application.put_env(:wardmast, :worktree_root, "/tmp/from-config-wt")

      assert Paths.worktree_root() == "/tmp/from-env-wt"
    end

    test "app config wins over default when env var is unset" do
      System.delete_env("WARDMAST_WORKTREE_ROOT")
      Application.put_env(:wardmast, :worktree_root, "/tmp/from-config-wt")

      assert Paths.worktree_root() == "/tmp/from-config-wt"
    end

    test "falls back to a $HOME-relative default when nothing is set" do
      System.delete_env("WARDMAST_WORKTREE_ROOT")
      Application.delete_env(:wardmast, :worktree_root)

      assert Paths.worktree_root() == Path.expand("~/dev/arbiter-worktrees")
    end

    test "raises a named-env-var error instead of crashing on a missing HOME" do
      System.delete_env("WARDMAST_WORKTREE_ROOT")
      Application.delete_env(:wardmast, :worktree_root)
      prior_home = System.get_env("HOME")
      System.delete_env("HOME")

      try do
        assert_raise RuntimeError, ~r/WARDMAST_WORKTREE_ROOT/, fn ->
          Paths.worktree_root()
        end
      after
        restore_env("HOME", prior_home)
      end
    end
  end

  describe "output_log_root/0" do
    test "env var wins over app config and default" do
      System.put_env("WARDMAST_OUTPUT_LOG_ROOT", "/tmp/from-env-log")
      Application.put_env(:wardmast, :output_log_root, "/tmp/from-config-log")

      assert Paths.output_log_root() == "/tmp/from-env-log"
    end

    test "app config wins over default when env var is unset" do
      System.delete_env("WARDMAST_OUTPUT_LOG_ROOT")
      Application.put_env(:wardmast, :output_log_root, "/tmp/from-config-log")

      assert Paths.output_log_root() == "/tmp/from-config-log"
    end

    test "falls back to a $HOME-relative default when nothing is set" do
      System.delete_env("WARDMAST_OUTPUT_LOG_ROOT")
      Application.delete_env(:wardmast, :output_log_root)

      assert Paths.output_log_root() == Path.expand("~/dev/arbiter-worker-logs")
    end
  end

  describe "coordinator_session_dirs/0" do
    test "defaults to none — metering is opt-in, never a guessed home directory" do
      System.delete_env("WARDMAST_COORDINATOR_SESSION_DIRS")
      Application.delete_env(:wardmast, :coordinator_session_dirs)
      assert Paths.coordinator_session_dirs() == []
    end

    test "the env var takes a colon- or comma-separated list, ~ expanded" do
      System.put_env("WARDMAST_COORDINATOR_SESSION_DIRS", "/tmp/a:/tmp/b,/tmp/c")
      assert Paths.coordinator_session_dirs() == ["/tmp/a", "/tmp/b", "/tmp/c"]
    end

    test "application config accepts a list or a single string" do
      System.delete_env("WARDMAST_COORDINATOR_SESSION_DIRS")
      Application.put_env(:wardmast, :coordinator_session_dirs, ["/tmp/x", "/tmp/y"])
      assert Paths.coordinator_session_dirs() == ["/tmp/x", "/tmp/y"]

      Application.put_env(:wardmast, :coordinator_session_dirs, "/tmp/z")
      assert Paths.coordinator_session_dirs() == ["/tmp/z"]
    end

    test "blank entries are dropped rather than becoming the cwd" do
      System.put_env("WARDMAST_COORDINATOR_SESSION_DIRS", "/tmp/a::,  ,/tmp/b")
      assert Paths.coordinator_session_dirs() == ["/tmp/a", "/tmp/b"]
    end
  end

  describe "worker_tmp_root/0 defaults" do
    test "resolves the absolute default with nothing configured" do
      keys = ["WARDMAST_WORKER_TMP_ROOT", "WARDMAST_SCRATCH_ROOT"]
      prior_env = Enum.map(keys, &{&1, System.get_env(&1)})

      prior_cfg = [
        worker_tmp_root: Application.get_env(:wardmast, :worker_tmp_root),
        scratch_root: Application.get_env(:wardmast, :scratch_root)
      ]

      on_exit(fn ->
        Enum.each(prior_env, fn {k, v} -> restore_env(k, v) end)
        Enum.each(prior_cfg, fn {k, v} -> restore_cfg(k, v) end)
      end)

      Enum.each(keys, &System.delete_env/1)
      Application.delete_env(:wardmast, :worker_tmp_root)
      Application.delete_env(:wardmast, :scratch_root)

      assert Paths.worker_tmp_root() == Path.join(Paths.scratch_root(), "worker-tmp")
      assert Path.type(Paths.worker_tmp_root()) == :absolute
    end
  end
end
