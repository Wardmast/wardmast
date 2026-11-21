defmodule Wardmast.SecretRefs.Keychain do
  @moduledoc """
  The `keychain:<service>#<account>` secret-ref backend: reads one item from the
  OS credential store, by shelling out to the platform's own tool.

    * macOS — Keychain, `security find-generic-password -s <service> -a <account> -w`
    * Linux — Secret Service (GNOME Keyring, KWallet, …), `secret-tool lookup
      service <service> account <account>`

  Only the item's *name* is ever on the command line; the value comes back on
  stdout and is never logged or written anywhere. This backend is **read-only**:
  it never creates or overwrites an item. Writing is the desktop shell's job, on
  first run (`docs/desktop-shell.md`), and a missing item must fail the boot
  rather than be recreated — a freshly generated Cloak key would orphan every
  secret already encrypted with the old one.

  Errors are `{:keychain, kind, "<service>#<account>"}` with `kind` one of
  `:not_found`, `:locked`, `:unavailable`, `:unsupported_os` or `:failed`; they
  carry no secret material. `Wardmast.SecretRefs.External.describe_error/1`
  turns them into a message that names the item and the fix.

  Tests inject the platform and the command runner with
  `config :wardmast, #{inspect(__MODULE__)}, os: :darwin | :linux, cmd: fun`
  where `fun.(binary, args, opts)` returns `{output, exit_status}` or `:enoent`.
  """

  alias Wardmast.Worker.ReleaseEnv

  @type kind :: :not_found | :locked | :unavailable | :unsupported_os | :failed
  @type error :: {:keychain, kind(), String.t()}

  @doc "Read the value of `service`/`account` from the OS credential store."
  @spec fetch(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()} | {:error, :empty}
  def fetch(service, account) do
    item = service <> "#" <> account

    case os() do
      :darwin ->
        run("security", ["find-generic-password", "-s", service, "-a", account, "-w"], item)

      :linux ->
        run("secret-tool", ["lookup", "service", service, "account", account], item)

      _ ->
        {:error, {:keychain, :unsupported_os, item}}
    end
  end

  # The value is read from stdout alone: GLib/D-Bus warnings on stderr must never
  # end up inside a key. Only a failed lookup is re-run with stderr merged in, to
  # classify it from the tool's message.
  defp run(binary, args, item) do
    case command(binary, args, stderr_to_stdout: false) do
      :enoent ->
        {:error, {:keychain, :unavailable, item}}

      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, :empty}
          value -> {:ok, value}
        end

      {stdout, status} ->
        output =
          case command(binary, args, stderr_to_stdout: true) do
            {merged, _} -> merged
            _ -> stdout
          end

        {:error, {:keychain, classify(os(), status, output), item}}
    end
  end

  # `security` exit codes: 44 errSecItemNotFound; 36 errSecInteractionNotAllowed
  # (locked, no UI to prompt); 51 the user cancelled the unlock prompt.
  defp classify(:darwin, 44, _), do: :not_found
  defp classify(:darwin, status, _) when status in [36, 51], do: :locked
  defp classify(:darwin, _, output), do: classify_text(output, :failed)

  # `secret-tool lookup` exits 1 for "no such item" with no output at all; a
  # locked collection or a missing bus shows up as stderr text.
  defp classify(:linux, _status, output), do: classify_text(output, nil)

  defp classify_text(output, default) do
    text = String.downcase(output)

    cond do
      String.contains?(text, ["locked", "denied", "user interaction is not allowed"]) ->
        :locked

      String.contains?(text, [
        "autolaunch",
        "org.freedesktop.secrets",
        "cannot connect",
        "no such interface",
        "dbus",
        "d-bus"
      ]) ->
        :unavailable

      default != nil ->
        default

      String.trim(text) == "" ->
        :not_found

      true ->
        :failed
    end
  end

  defp command(binary, args, opts) do
    case Application.get_env(:wardmast, __MODULE__, [])[:cmd] do
      fun when is_function(fun, 3) -> fun.(binary, args, opts)
      _ -> system_cmd(binary, args, opts)
    end
  end

  # `binary` is a fixed literal ("security" / "secret-tool"), never user input.
  # `ReleaseEnv.cmd/3` spawns it directly (no shell) with the release env scrubbed.
  defp system_cmd(binary, args, opts) do
    case System.find_executable(binary) do
      nil -> :enoent
      path -> ReleaseEnv.cmd(path, args, opts)
    end
  rescue
    _ -> :enoent
  end

  defp os do
    case Application.get_env(:wardmast, __MODULE__, [])[:os] do
      nil ->
        case :os.type() do
          {:unix, :darwin} -> :darwin
          {:unix, :linux} -> :linux
          {_, other} -> other
        end

      os ->
        os
    end
  end
end
