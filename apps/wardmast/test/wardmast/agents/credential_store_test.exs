defmodule Wardmast.Agents.CredentialStoreTest do
  use ExUnit.Case, async: true

  alias Wardmast.Agents.CredentialStore

  @darwin {:unix, :darwin}
  @linux {:unix, :linux}

  setup do
    dir = Path.join(System.tmp_dir!(), "arb-credstore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "detect(:claude, ...)" do
    test "linux: credential is the .credentials.json file, readable, no warning", %{dir: dir} do
      result = CredentialStore.detect(:claude, os: @linux, source_dir: dir)

      assert %{agent: :claude, store: :file, arbiter_readable?: true, warning: nil} = result
    end

    test "darwin with a .credentials.json on disk: file store, readable", %{dir: dir} do
      File.write!(Path.join(dir, ".credentials.json"), "{}")
      result = CredentialStore.detect(:claude, os: @darwin, source_dir: dir)

      assert %{store: :file, arbiter_readable?: true, warning: nil} = result
    end

    test "darwin with no .credentials.json: Keychain, unreadable, warns about mode B", %{dir: dir} do
      result = CredentialStore.detect(:claude, os: @darwin, source_dir: dir)

      assert %{store: :keychain, arbiter_readable?: false, warning: warning} = result
      assert warning =~ "Keychain"
      assert warning =~ "mode B"
      assert warning =~ "setup-token"
    end

    test "darwin with no source dir at all is treated as Keychain", _ do
      assert %{store: :keychain, arbiter_readable?: false} =
               CredentialStore.detect(:claude, os: @darwin, source_dir: nil)
    end
  end

  describe "detect(:agy, ...)" do
    test "linux: Secret Service, no warning (agy's own store, survives HOME redirect)" do
      assert %{agent: :agy, store: :secret_service, warning: nil} =
               CredentialStore.detect(:agy, os: @linux)
    end

    test "darwin: Keychain, unreadable by Arbiter, warns" do
      result = CredentialStore.detect(:agy, os: @darwin)

      assert %{store: :keychain, arbiter_readable?: false, warning: warning} = result
      assert warning =~ "Keychain"
      assert warning =~ "agy"
    end
  end

  describe "available?(:agy, ...)" do
    test "darwin: available when the `security` CLI is present" do
      assert CredentialStore.available?(:agy, os: @darwin, security_cli: true)
    end

    test "darwin: unavailable when the `security` CLI is missing" do
      refute CredentialStore.available?(:agy, os: @darwin, security_cli: false)
    end

    test "linux: delegates to the Secret Service probe stub" do
      assert CredentialStore.available?(:agy, os: @linux, secret_service: true)
      refute CredentialStore.available?(:agy, os: @linux, secret_service: false)
    end

    test "linux ignores the darwin-only security_cli stub" do
      refute CredentialStore.available?(:agy,
               os: @linux,
               security_cli: true,
               secret_service: false
             )
    end
  end

  describe "secret_service?/1" do
    test "true only for a non-darwin host" do
      assert CredentialStore.secret_service?(os: @linux)
      refute CredentialStore.secret_service?(os: @darwin)
    end
  end
end
