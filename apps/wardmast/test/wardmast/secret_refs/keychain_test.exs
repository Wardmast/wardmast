defmodule Wardmast.SecretRefs.KeychainTest do
  use ExUnit.Case, async: false

  alias Wardmast.SecretRefs.{Cache, External, Keychain}

  @cloak_value Base.encode64(String.duplicate("k", 32))

  setup do
    prev = Application.get_env(:wardmast, Keychain)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()

      if prev,
        do: Application.put_env(:wardmast, Keychain, prev),
        else: Application.delete_env(:wardmast, Keychain)

      System.delete_env("WARDMAST_CLOAK_KEY_REF")
      System.delete_env("WARDMAST_CLOAK_KEY")
      System.delete_env("SECRET_KEY_BASE_REF")
    end)

    :ok
  end

  # Stubs the OS command: records every (binary, args) call in the test process
  # and answers with `reply`.
  defp stub(os, reply) do
    test = self()

    cmd = fn binary, args ->
      send(test, {:cmd, binary, args})
      if is_function(reply), do: reply.(binary, args), else: reply
    end

    Application.put_env(:wardmast, Keychain, os: os, cmd: cmd)
  end

  describe "parse/1" do
    test "keychain:<service>#<account>" do
      assert {:ok, %{scheme: :keychain, target: "dev.arbiter", key: "cloak-key"}} =
               External.parse("keychain:dev.arbiter#cloak-key")

      assert External.external?("keychain:dev.arbiter#cloak-key")
      assert External.scheme_name("keychain:dev.arbiter#cloak-key") == "keychain"
    end

    test "both service and account are required" do
      assert External.parse("keychain:") == :error
      assert External.parse("keychain:service-only") == :error
      assert External.parse("keychain:service#") == :error
      assert External.parse("keychain:#account") == :error
    end
  end

  describe "macOS Keychain" do
    test "reads the item through `security find-generic-password -w`" do
      stub(:darwin, {@cloak_value <> "\n", 0})

      assert {:ok, @cloak_value} = External.resolve("keychain:dev.arbiter#cloak-key")

      assert_received {:cmd, "security", args}
      assert args == ["find-generic-password", "-s", "dev.arbiter", "-a", "cloak-key", "-w"]
    end

    test "exit 44 is a missing item, naming the item and the fix" do
      stub(
        :darwin,
        {"security: SecKeychainSearchCopyNext: The specified item could not be found.", 44}
      )

      assert {:error, {:keychain, :not_found, "dev.arbiter#cloak-key"} = reason} =
               External.resolve("keychain:dev.arbiter#cloak-key")

      message = External.describe_error(reason)
      assert message =~ "dev.arbiter#cloak-key"
      assert message =~ "not found"
      assert message =~ "will not generate"
    end

    test "a locked keychain is reported as locked, not as missing" do
      stub(:darwin, {"User interaction is not allowed.", 36})

      assert {:error, {:keychain, :locked, _} = reason} =
               External.resolve("keychain:dev.arbiter#cloak-key")

      assert External.describe_error(reason) =~ "unlock-keychain"
    end

    test "a missing `security` binary is unavailable" do
      stub(:darwin, :enoent)

      assert {:error, {:keychain, :unavailable, _}} =
               External.resolve("keychain:dev.arbiter#cloak-key")
    end
  end

  describe "Linux Secret Service" do
    test "reads the item through `secret-tool lookup`" do
      stub(:linux, {@cloak_value <> "\n", 0})

      assert {:ok, @cloak_value} = External.resolve("keychain:dev.arbiter#cloak-key")

      assert_received {:cmd, "secret-tool", args}
      assert args == ["lookup", "service", "dev.arbiter", "account", "cloak-key"]
    end

    test "exit 1 with no output is a missing item" do
      stub(:linux, {"", 1})

      assert {:error, {:keychain, :not_found, "dev.arbiter#cloak-key"} = reason} =
               External.resolve("keychain:dev.arbiter#cloak-key")

      assert External.describe_error(reason) =~ "dev.arbiter#cloak-key"
    end

    test "a locked collection is reported as locked" do
      stub(:linux, {"secret-tool: Cannot get secret of a locked object", 1})

      assert {:error, {:keychain, :locked, _} = reason} =
               External.resolve("keychain:dev.arbiter#cloak-key")

      assert External.describe_error(reason) =~ "unlock"
    end

    test "no Secret Service on the bus is unavailable" do
      stub(
        :linux,
        {"secret-tool: Cannot autolaunch D-Bus without X11 $DISPLAY", 1}
      )

      assert {:error, {:keychain, :unavailable, _} = reason} =
               External.resolve("keychain:dev.arbiter#cloak-key")

      assert External.describe_error(reason) =~ "Secret Service"
    end

    test "a missing `secret-tool` binary is unavailable" do
      stub(:linux, :enoent)

      assert {:error, {:keychain, :unavailable, _}} =
               External.resolve("keychain:dev.arbiter#cloak-key")
    end

    test "an empty secret is an error, never an empty key" do
      stub(:linux, {"\n", 0})
      assert {:error, :empty} = External.resolve("keychain:dev.arbiter#cloak-key")
    end
  end

  test "other platforms are unsupported" do
    stub(:windows, {"x", 0})

    assert {:error, {:keychain, :unsupported_os, _}} =
             External.resolve("keychain:dev.arbiter#cloak-key")

    refute_received {:cmd, _, _}
  end

  describe "boot-time refs" do
    test "WARDMAST_CLOAK_KEY_REF and SECRET_KEY_BASE_REF resolve through keychain:" do
      stub(:linux, fn _bin, args -> {"value-for-" <> List.last(args) <> "\n", 0} end)

      System.put_env("WARDMAST_CLOAK_KEY_REF", "keychain:dev.arbiter#cloak-key")
      System.put_env("SECRET_KEY_BASE_REF", "keychain:dev.arbiter#secret-key-base")

      assert External.env_or_ref!("WARDMAST_CLOAK_KEY") == "value-for-cloak-key"
      assert External.env_or_ref!("SECRET_KEY_BASE") == "value-for-secret-key-base"
    end

    test "a missing item fails the boot, naming the variable and the item, and does not fall back to an inline key" do
      stub(:linux, {"", 1})
      System.put_env("WARDMAST_CLOAK_KEY_REF", "keychain:dev.arbiter#cloak-key")
      System.put_env("WARDMAST_CLOAK_KEY", @cloak_value)

      error = assert_raise RuntimeError, fn -> External.env_or_ref!("WARDMAST_CLOAK_KEY") end
      assert error.message =~ "WARDMAST_CLOAK_KEY_REF=keychain:dev.arbiter#cloak-key"
      assert error.message =~ "not found"
    end

    test "Vault.key!/0 raises on a locked keychain and never generates a key" do
      stub(:darwin, {"User interaction is not allowed.", 36})
      System.put_env("WARDMAST_CLOAK_KEY_REF", "keychain:dev.arbiter#cloak-key")

      error = assert_raise RuntimeError, fn -> Wardmast.Vault.key!() end
      assert error.message =~ "dev.arbiter#cloak-key"
      assert error.message =~ "locked"

      # One lookup, nothing that stores: no add/store command was ever issued.
      assert_received {:cmd, "security", ["find-generic-password" | _]}
      refute_received {:cmd, _, _}
    end

    test "Vault.key!/0 decodes a key held in the keychain" do
      stub(:linux, {@cloak_value <> "\n", 0})
      System.put_env("WARDMAST_CLOAK_KEY_REF", "keychain:dev.arbiter#cloak-key")
      assert byte_size(Wardmast.Vault.key!()) == 32
    end
  end

  test "values are redacted via the cached set and absent from error text" do
    stub(:linux, {@cloak_value <> "\n", 0})
    assert {:ok, @cloak_value} = External.resolve("keychain:dev.arbiter#cloak-key")
    assert @cloak_value in External.cached_values()

    Cache.clear()
    stub(:linux, {"leaked-" <> @cloak_value, 7})
    {:error, reason} = External.resolve("keychain:dev.arbiter#cloak-key")
    refute External.describe_error(reason) =~ @cloak_value
    refute inspect(reason) =~ @cloak_value
  end
end
