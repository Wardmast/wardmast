defmodule Wardmast.Screenshots.SectionTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Section

  @rows [
    %{
      label: "Edit patient modal",
      before: {:image, "https://x/b1.png"},
      after: {:image, "https://x/a1.png"}
    },
    %{
      label: "Settings",
      before: {:text, "new at this commit"},
      after: {:image, "https://x/a2.png"}
    }
  ]

  describe "render/1" do
    test "renders a Page/state | Before | After table with inline images" do
      out = Section.render(@rows)

      assert out =~ "## Screenshots"
      assert out =~ "| Page/state | Before | After |"

      assert out =~
               "| Edit patient modal | ![before](https://x/b1.png) | ![after](https://x/a1.png) |"

      assert out =~ "| Settings | _new at this commit_ | ![after](https://x/a2.png) |"
      assert String.starts_with?(out, Section.start_marker())
      assert String.ends_with?(out, Section.end_marker())
    end

    test "escapes pipes and newlines in labels and reasons so a row cannot break the table" do
      out =
        Section.render([%{label: "a | b\nc", before: {:text, "x | y"}, after: {:text, "z"}}])

      assert out =~ "| a \\| b c | _x \\| y_ | _z_ |"
    end
  end

  describe "compose/2" do
    test "appends the section after the description when none exists" do
      section = Section.render(@rows)
      body = Section.compose("Summary text", section)

      assert body == "Summary text\n\n" <> section
    end

    test "replaces an existing section in place instead of appending a second" do
      first = Section.render(@rows)
      second = Section.render([%{label: "Only", before: {:image, "b"}, after: {:image, "a"}}])

      body = "Summary\n\n" <> first <> "\n\n## Test plan\n- ok"
      out = Section.compose(body, second)

      assert out == "Summary\n\n" <> second <> "\n\n## Test plan\n- ok"
      assert length(String.split(out, Section.start_marker())) == 2
    end

    test "collapses several stale blocks into one" do
      s = Section.render(@rows)
      out = Section.compose("A\n\n" <> s <> "\n\nB\n\n" <> s, s)
      assert length(String.split(out, Section.start_marker())) == 2
    end

    test "composes into an empty or nil description" do
      s = Section.render(@rows)
      assert Section.compose(nil, s) == s
      assert Section.compose("", s) == s
    end

    test "is idempotent" do
      s = Section.render(@rows)
      once = Section.compose("Summary", s)
      assert Section.compose(once, s) == once
    end
  end
end

defmodule Wardmast.Screenshots.SectionSizeGuardTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Section

  test "rows beyond the size cap are dropped with a visible count, never silently" do
    rows =
      for i <- 1..50 do
        %{
          label: "Page #{i}",
          before: {:image, "https://x/b#{i}.png"},
          after: {:image, "https://x/a#{i}.png"}
        }
      end

    out = Section.render(rows, max_chars: 2_000)

    assert String.length(out) <= 2_000
    assert out =~ "Page 1 "
    refute out =~ "Page 50 "
    assert out =~ ~r/_\d+ more not shown/
    assert String.ends_with?(out, Section.end_marker())
  end
end
