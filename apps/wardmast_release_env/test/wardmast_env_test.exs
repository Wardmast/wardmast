defmodule Wardmast.EnvTest do
  # Mutates the OS environment and the once-only warning registry, both global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardmast.Env

  @new "WARDMAST_ENVTEST_X"
  @arb "ARB_ENVTEST_X"
  @arbiter "ARBITER_ENVTEST_X"

  setup do
    clear()
    Env.reset_warnings()

    on_exit(fn ->
      clear()
      Env.reset_warnings()
    end)
  end

  defp clear, do: Enum.each([@new, @arb, @arbiter], &System.delete_env/1)

  describe "get/2" do
    test "WARDMAST_X wins over ARB_X and ARBITER_X, with no deprecation warning" do
      System.put_env(@new, "new")
      System.put_env(@arb, "arb")
      System.put_env(@arbiter, "arbiter")

      log = capture_log(fn -> assert Env.get(@new) == "new" end)

      assert log == ""
    end

    test "ARB_X alone still works and logs a deprecation" do
      System.put_env(@arb, "legacy")

      log = capture_log(fn -> assert Env.get(@new) == "legacy" end)

      assert log =~ "deprecated"
      assert log =~ @arb
      assert log =~ @new
    end

    test "ARBITER_X alone still works and logs a deprecation" do
      System.put_env(@arbiter, "legacy")

      log = capture_log(fn -> assert Env.get(@new) == "legacy" end)

      assert log =~ @arbiter
      assert log =~ @new
    end

    test "ARB_X is preferred over ARBITER_X when both are set" do
      System.put_env(@arb, "arb")
      System.put_env(@arbiter, "arbiter")

      capture_log(fn -> assert Env.get(@new) == "arb" end)
    end

    test "the deprecation is logged once per legacy name, not once per read" do
      System.put_env(@arb, "legacy")

      log =
        capture_log(fn ->
          for _ <- 1..5, do: assert(Env.get(@new) == "legacy")
        end)

      assert length(String.split(log, "deprecated")) == 2
    end

    test "concurrent first reads still log exactly once" do
      System.put_env(@arb, "legacy")

      log =
        capture_log(fn ->
          1..20
          |> Task.async_stream(fn _ -> Env.get(@new) end, max_concurrency: 20)
          |> Stream.run()
        end)

      assert length(String.split(log, "deprecated")) == 2
    end

    test "returns the default when nothing is set" do
      assert Env.get(@new) == nil
      assert Env.get(@new, "dflt") == "dflt"
    end

    test "an empty WARDMAST_X is a set value, like System.get_env/1" do
      System.put_env(@new, "")
      System.put_env(@arb, "legacy")

      assert Env.get(@new, "dflt") == ""
    end

    test "rejects a name that is not WARDMAST_-prefixed" do
      assert_raise ArgumentError, ~r/WARDMAST_/, fn -> Env.get("ARB_ENVTEST_X") end
    end
  end

  describe "get/3 over an explicit env map" do
    test "same precedence, same one-time warning" do
      assert Env.get_from(%{@new => "new", @arb => "arb"}, @new) == "new"

      log =
        capture_log(fn ->
          assert Env.get_from(%{@arb => "legacy"}, @new) == "legacy"
          assert Env.get_from(%{@arb => "legacy"}, @new) == "legacy"
        end)

      assert length(String.split(log, "deprecated")) == 2
      assert Env.get_from(%{}, @new, "d") == "d"
    end
  end

  describe "fetch/1 and fetch!/1" do
    test "fetch returns :error when unset, {:ok, v} from either name" do
      assert Env.fetch(@new) == :error
      System.put_env(@arb, "legacy")
      capture_log(fn -> assert Env.fetch(@new) == {:ok, "legacy"} end)
      System.put_env(@new, "new")
      assert Env.fetch(@new) == {:ok, "new"}
    end

    test "fetch! raises naming the new variable" do
      assert_raise System.EnvError, ~r/#{@new}/, fn -> Env.fetch!(@new) end
    end
  end

  describe "read/1" do
    test "applies the fallback to WARDMAST_ names and leaves other names alone" do
      System.put_env(@arb, "legacy")
      capture_log(fn -> assert Env.read(@new) == "legacy" end)
      assert Env.read(@arb) == "legacy"
      assert Env.read("ENVTEST_UNSET_VAR") == nil
    end
  end

  describe "legacy_names/1" do
    test "maps WARDMAST_ to the ARB_ and ARBITER_ spellings" do
      assert Env.legacy_names("WARDMAST_CLOAK_KEY") == ["ARB_CLOAK_KEY", "ARBITER_CLOAK_KEY"]
    end
  end
end
