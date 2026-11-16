defmodule Wardmast.TestDbPartitionTest do
  use ExUnit.Case, async: true

  # config/test.exs requires config/support/test_db_partition.ex before this
  # suite starts, so Wardmast.TestDbPartition is already loaded.

  test "suffix is deterministic for the same cwd" do
    assert Wardmast.TestDbPartition.suffix("/tmp/worktree-a") ==
             Wardmast.TestDbPartition.suffix("/tmp/worktree-a")
  end

  test "suffix differs across different cwds" do
    refute Wardmast.TestDbPartition.suffix("/tmp/worktree-a") ==
             Wardmast.TestDbPartition.suffix("/tmp/worktree-b")
  end
end
