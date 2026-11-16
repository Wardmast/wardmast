defmodule WardmastWeb.EndpointConfigTest do
  use ExUnit.Case

  describe "config/runtime.exs in dev mode" do
    test "requires SECRET_KEY_BASE environment variable for dev config" do
      # Simulate loading dev config without SECRET_KEY_BASE set
      # The runtime config should raise an error when the env var is missing
      assert_raise RuntimeError, ~r/SECRET_KEY_BASE is missing/, fn ->
        # Clear the env var if it exists
        original_value = System.get_env("SECRET_KEY_BASE")
        System.delete_env("SECRET_KEY_BASE")

        try do
          # Attempt to load the config by re-evaluating the runtime block
          # This simulates what happens when the app starts in dev mode
          Config.Reader.read!("../../config/runtime.exs", env: :dev)
        after
          # Restore original value
          if original_value do
            System.put_env("SECRET_KEY_BASE", original_value)
          end
        end
      end
    end
  end

  # bd-1c4pg3: the dashboard's auth model is "a loopback peer is trusted;
  # there is no login" — default the bind address to loopback in prod/release,
  # with WARDMAST_BIND_ADDRESS as the explicit, operator-opted-in override.
  describe "config/runtime.exs bind address (prod)" do
    setup do
      env = %{
        "SECRET_KEY_BASE" => System.get_env("SECRET_KEY_BASE"),
        "DATABASE_PATH" => System.get_env("DATABASE_PATH")
      }

      on_exit(fn ->
        for {k, v} <- env do
          if v, do: System.put_env(k, v), else: System.delete_env(k)
        end
      end)

      System.put_env("SECRET_KEY_BASE", env["SECRET_KEY_BASE"] || "test-secret-key-base")
      :ok
    end

    defp read_prod_http_ip do
      config = Config.Reader.read!("../../config/runtime.exs", env: :prod)
      get_in(config, [:wardmast_web, WardmastWeb.Endpoint, :http, :ip])
    end

    test "defaults to 127.0.0.1 when WARDMAST_BIND_ADDRESS is unset" do
      System.delete_env("WARDMAST_BIND_ADDRESS")
      assert read_prod_http_ip() == {127, 0, 0, 1}
    end

    test "WARDMAST_BIND_ADDRESS overrides the bind address" do
      System.put_env("WARDMAST_BIND_ADDRESS", "0.0.0.0")
      on_exit(fn -> System.delete_env("WARDMAST_BIND_ADDRESS") end)

      assert read_prod_http_ip() == {0, 0, 0, 0}
    end

    test "an invalid WARDMAST_BIND_ADDRESS raises a clear error" do
      System.put_env("WARDMAST_BIND_ADDRESS", "not-an-ip")
      on_exit(fn -> System.delete_env("WARDMAST_BIND_ADDRESS") end)

      assert_raise RuntimeError, ~r/WARDMAST_BIND_ADDRESS is not a valid IP address/, fn ->
        read_prod_http_ip()
      end
    end
  end

  describe "config/runtime.exs bind address (dev)" do
    setup do
      previous = System.get_env("SECRET_KEY_BASE")
      System.put_env("SECRET_KEY_BASE", previous || "test-secret-key-base")

      on_exit(fn ->
        if previous,
          do: System.put_env("SECRET_KEY_BASE", previous),
          else: System.delete_env("SECRET_KEY_BASE")
      end)
    end

    defp read_dev_http_ip do
      config = Config.Reader.read!("../../config/runtime.exs", env: :dev)
      get_in(config, [:wardmast_web, WardmastWeb.Endpoint, :http, :ip])
    end

    test "defaults to 127.0.0.1 when WARDMAST_BIND_ADDRESS is unset" do
      System.delete_env("WARDMAST_BIND_ADDRESS")
      assert read_dev_http_ip() == {127, 0, 0, 1}
    end

    test "WARDMAST_BIND_ADDRESS overrides the bind address" do
      System.put_env("WARDMAST_BIND_ADDRESS", "::1")
      on_exit(fn -> System.delete_env("WARDMAST_BIND_ADDRESS") end)

      assert read_dev_http_ip() == {0, 0, 0, 0, 0, 0, 0, 1}
    end
  end
end
