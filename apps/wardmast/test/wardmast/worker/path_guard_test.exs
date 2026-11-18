defmodule Wardmast.Worker.PathGuardTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.PathGuard

  @moduletag :tmp_dir

  describe "case_collision/1" do
    test "flags a sibling differing only by case", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "Fix-Foo"))

      assert {:error, {:path_case_collision, _, existing}} =
               PathGuard.case_collision(Path.join(dir, "fix-foo"))

      assert Path.basename(existing) == "Fix-Foo"
    end

    test "exact-case leaf and unrelated names are fine", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "fix-foo"))
      assert :ok = PathGuard.case_collision(Path.join(dir, "fix-foo"))
      assert :ok = PathGuard.case_collision(Path.join(dir, "other"))
      assert :ok = PathGuard.case_collision(Path.join([dir, "missing-parent", "x"]))
    end
  end

  describe "within?/2" do
    test "a symlink escaping the root is not within it", %{tmp_dir: dir} do
      root = Path.join(dir, "root")
      outside = Path.join(dir, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(root, "link"))

      refute PathGuard.within?(Path.join(root, "link/x"), root)
      assert PathGuard.within?(Path.join(root, "plain/x"), root)
      assert PathGuard.within?(root, root)
    end

    test "a symlinked root is resolved", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(Path.join(real, "wt"))
      File.ln_s!(real, Path.join(dir, "alias"))

      assert PathGuard.within?(Path.join(dir, "alias/wt"), real)
      assert PathGuard.within?(Path.join(real, "wt"), Path.join(dir, "alias"))
      refute PathGuard.within?(Path.join(dir, "real-sibling"), real)
    end
  end
end
