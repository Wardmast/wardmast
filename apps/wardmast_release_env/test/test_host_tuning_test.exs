defmodule WardmastReleaseEnv.TestHostTuningTest do
  # Mutates $TMPDIR (restored in on_exit), so it cannot run beside tests that read it.
  use ExUnit.Case, async: false

  # bd-datu4q: scripts/test_host_tuning.exs is shared by the three app test helpers.
  # It evaluates to a map of two functions; both are no-ops on a plain Linux host.
  @script Path.expand("../../../scripts/test_host_tuning.exs", __DIR__)

  setup_all do
    {tuning, _} = Code.eval_file(@script)
    %{tuning: tuning}
  end

  describe "ex_unit_opts" do
    test "darwin widens assert_receive_timeout", %{tuning: t} do
      assert t.ex_unit_opts.(%{}, {:unix, :darwin}) == [assert_receive_timeout: 1_000]
    end

    test "linux leaves ExUnit's defaults alone", %{tuning: t} do
      assert t.ex_unit_opts.(%{}, {:unix, :linux}) == []
    end

    test "WARDMAST_TEST_EXCLUDE_LINUX=1 reproduces the macOS subset on any host", %{tuning: t} do
      assert t.ex_unit_opts.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => "1"}, {:unix, :linux}) ==
               [assert_receive_timeout: 1_000]

      assert t.ex_unit_opts.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => "0"}, {:unix, :linux}) == []
    end
  end

  describe "normalize_tmpdir" do
    setup %{tuning: tuning} do
      base = Path.join(System.tmp_dir!(), "host-tuning-#{System.unique_integer([:positive])}")
      real = Path.join(base, "real")
      link = Path.join(base, "link")
      File.mkdir_p!(real)
      :ok = File.ln_s(real, link)

      old = System.get_env("TMPDIR")

      on_exit(fn ->
        if old, do: System.put_env("TMPDIR", old), else: System.delete_env("TMPDIR")
        File.rm_rf(base)
      end)

      {:ok, real: File.cd!(real, fn -> File.cwd!() end), link: link, normalize: tuning.normalize_tmpdir}
    end

    test "on darwin $TMPDIR becomes its real path (the /var -> /private/var symlink)", ctx do
      System.put_env("TMPDIR", ctx.link)

      assert ctx.normalize.(%{}, {:unix, :darwin}) == ctx.real
      assert System.get_env("TMPDIR") == ctx.real
      assert System.tmp_dir!() == ctx.real
    end

    test "on linux $TMPDIR is left exactly as it was", ctx do
      System.put_env("TMPDIR", ctx.link)

      assert ctx.normalize.(%{}, {:unix, :linux}) == System.tmp_dir!()
      assert System.get_env("TMPDIR") == ctx.link
    end
  end
end
