defmodule Wardmast.Nodes.TranscriptsTest do
  @moduledoc """
  RW11 (`docs/design/remote-workers.md` §7.6): the sanitising transcript extractor.
  A node's tar is untrusted: it may name absolute or `..` paths, carry links, ride
  files outside `projects/`, or be a zip-bomb-shaped size.
  """
  use ExUnit.Case, async: true

  alias Wardmast.NodeAgent.Transcripts, as: Pack
  alias Wardmast.Nodes.Transcripts

  @moduletag :tmp_dir

  # entries: [{name, binary}] regular files; [{name, :dir}]; [{name, {:symlink, target}}]
  defp tar!(dir, entries, opts \\ []) do
    path = Path.join(dir, "t-#{System.unique_integer([:positive])}.tar")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write | opts])

    for {name, body} <- entries do
      case body do
        bin when is_binary(bin) ->
          :ok = :erl_tar.add(tar, {String.to_charlist(name), bin}, [])

        :dir ->
          :ok =
            :erl_tar.add(
              tar,
              String.to_charlist(Path.join(dir, "stage-dir")),
              String.to_charlist(name),
              []
            )

        {:symlink, target} ->
          link = Path.join(dir, "lnk-#{System.unique_integer([:positive])}")
          File.ln_s!(target, link)
          :ok = :erl_tar.add(tar, String.to_charlist(link), String.to_charlist(name), [])
      end
    end

    :ok = :erl_tar.close(tar)
    path
  end

  setup %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "stage-dir"))
    dest = Path.join(tmp, "config")
    File.mkdir_p!(dest)
    %{dest: dest}
  end

  test "extracts *.jsonl under projects/, including subagents", %{tmp_dir: tmp, dest: dest} do
    tar =
      tar!(tmp, [
        {"projects/-work-tree/abc.jsonl", ~s({"a":1}\n)},
        {"projects/-work-tree/abc/subagents/agent-1.jsonl", ~s({"b":2}\n)}
      ])

    assert {:ok, %{files: 2, bytes: 16, skipped: []}} = Transcripts.extract(tar, dest)
    assert File.read!(Path.join(dest, "projects/-work-tree/abc.jsonl")) == ~s({"a":1}\n)
    assert File.exists?(Path.join(dest, "projects/-work-tree/abc/subagents/agent-1.jsonl"))
  end

  test "works on a gzipped tar", %{tmp_dir: tmp, dest: dest} do
    tar = tar!(tmp, [{"projects/p/s.jsonl", "x\n"}], [:compressed])
    assert {:ok, %{files: 1}} = Transcripts.extract(tar, dest)
  end

  test "unwanted regular files are skipped, not extracted", %{tmp_dir: tmp, dest: dest} do
    tar =
      tar!(tmp, [
        {"projects/p/s.jsonl", "x\n"},
        {"projects/p/notes.txt", "n"},
        {".credentials.json", "{}"},
        {"settings.json", "{}"}
      ])

    assert {:ok, %{files: 1, skipped: skipped}} = Transcripts.extract(tar, dest)
    assert Enum.sort(skipped) == [".credentials.json", "projects/p/notes.txt", "settings.json"]
    refute File.exists?(Path.join(dest, ".credentials.json"))
    refute File.exists?(Path.join(dest, "settings.json"))
  end

  test "an absolute or .. path rejects the whole archive and writes nothing", %{
    tmp_dir: tmp,
    dest: dest
  } do
    for bad <- [
          "/etc/evil.jsonl",
          "../escape.jsonl",
          "projects/../../escape.jsonl",
          "projects/a/../../../x.jsonl"
        ] do
      tar = tar!(tmp, [{"projects/p/ok.jsonl", "x\n"}, {bad, "evil"}])
      assert {:error, {:unsafe_path, _}} = Transcripts.extract(tar, dest), bad
    end

    assert File.ls!(dest) == []
    refute File.exists?(Path.join(tmp, "escape.jsonl"))
  end

  test "a symlink entry rejects the whole archive", %{tmp_dir: tmp, dest: dest} do
    tar =
      tar!(tmp, [
        {"projects/p/ok.jsonl", "x\n"},
        {"projects/p/link.jsonl", {:symlink, "/etc/passwd"}}
      ])

    assert {:error, {:unsafe_entry, "projects/p/link.jsonl", _type}} =
             Transcripts.extract(tar, dest)

    assert File.ls!(dest) == []
  end

  test "byte caps: per file and in total", %{tmp_dir: tmp, dest: dest} do
    tar =
      tar!(tmp, [
        {"projects/p/a.jsonl", String.duplicate("x", 600)},
        {"projects/p/b.jsonl", String.duplicate("x", 600)}
      ])

    assert {:error, {:too_large, :file, _}} = Transcripts.extract(tar, dest, max_file_bytes: 500)
    assert {:error, {:too_large, :total, _}} = Transcripts.extract(tar, dest, max_bytes: 1_000)
    assert {:ok, %{files: 2}} = Transcripts.extract(tar, dest, max_bytes: 2_000)
  end

  test "an entry-count cap", %{tmp_dir: tmp, dest: dest} do
    tar = tar!(tmp, for(i <- 1..5, do: {"projects/p/#{i}.jsonl", "x\n"}))
    assert {:error, {:too_many_entries, _}} = Transcripts.extract(tar, dest, max_entries: 3)
  end

  test "will not write through a symlink already in the destination", %{tmp_dir: tmp, dest: dest} do
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(dest, "projects"))
    tar = tar!(tmp, [{"projects/p/s.jsonl", "x\n"}])

    assert {:error, {:unsafe_destination, _}} = Transcripts.extract(tar, dest)
    assert File.ls!(outside) == []
  end

  test "garbage is a clean error", %{tmp_dir: tmp, dest: dest} do
    path = Path.join(tmp, "junk.tar")
    File.write!(path, "this is not a tar archive at all")
    assert {:error, {:bad_archive, _}} = Transcripts.extract(path, dest)
  end

  test "pack/2 builds what extract/2 takes: jsonl under projects/ only, no links", %{
    tmp_dir: tmp,
    dest: dest
  } do
    src = Path.join(tmp, "node-config")
    File.mkdir_p!(Path.join(src, "projects/p/s/subagents"))
    File.write!(Path.join(src, "projects/p/s.jsonl"), "a\n")
    File.write!(Path.join(src, "projects/p/s/subagents/agent-1.jsonl"), "b\n")
    File.write!(Path.join(src, "projects/p/other.txt"), "no")
    File.write!(Path.join(src, ".credentials.json"), "secret")
    File.ln_s!("/etc/passwd", Path.join(src, "projects/p/link.jsonl"))

    out = Path.join(tmp, "out.tar.gz")
    assert {:ok, %{files: 2}} = Pack.pack(src, out)
    assert {:ok, %{files: 2, skipped: []}} = Transcripts.extract(out, dest)
    assert File.read!(Path.join(dest, "projects/p/s.jsonl")) == "a\n"
    refute File.exists?(Path.join(dest, ".credentials.json"))
    refute File.exists?(Path.join(dest, "projects/p/link.jsonl"))
  end

  # SI8 (`docs/design/remote-workers.md` §21.3.3): a Codex run's rollouts
  # (`sessions/YYYY/MM/DD/rollout-*.jsonl`) ride the same upload as Claude's `projects/**`;
  # the credential never does.
  describe "Codex rollouts (SI8)" do
    @rollout "sessions/2026/11/19/rollout-2026-11-19T10-00-00-thread1.jsonl"

    defp rollout_body do
      ~s({"timestamp":"2026-11-19T10:00:00Z","type":"session_meta","payload":{"session_id":"thread1"}}\n) <>
        ~s({"timestamp":"2026-11-19T10:00:05Z","type":"event_msg","payload":{"type":"token_count",) <>
        ~s("info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":200,) <>
        ~s("cache_write_input_tokens":0,"output_tokens":340,"reasoning_output_tokens":0}}}}\n)
    end

    test "extracts *.jsonl under sessions/ and nothing else there", %{tmp_dir: tmp, dest: dest} do
      tar =
        tar!(tmp, [
          {@rollout, rollout_body()},
          {"sessions/2026/11/19/notes.txt", "no"},
          {"auth.json", "{\"tokens\":{}}"},
          {"config.toml", "x"},
          {"AGENTS.md", "x"},
          {"rules/arbiter.rules", "x"}
        ])

      assert {:ok, %{files: 1, skipped: skipped}} = Transcripts.extract(tar, dest)

      assert Enum.sort(skipped) ==
               [
                 "AGENTS.md",
                 "auth.json",
                 "config.toml",
                 "rules/arbiter.rules",
                 "sessions/2026/11/19/notes.txt"
               ]

      assert File.read!(Path.join(dest, @rollout)) == rollout_body()
      refute File.exists?(Path.join(dest, "auth.json"))
      assert File.ls!(dest) == ["sessions"]
    end

    test "a symlink or a .. path under sessions/ still rejects the whole archive", %{
      tmp_dir: tmp,
      dest: dest
    } do
      link = tar!(tmp, [{@rollout, "x\n"}, {"sessions/a/l.jsonl", {:symlink, "/etc/passwd"}}])
      assert {:error, {:unsafe_entry, "sessions/a/l.jsonl", _}} = Transcripts.extract(link, dest)

      up = tar!(tmp, [{@rollout, "x\n"}, {"sessions/../../x.jsonl", "evil"}])
      assert {:error, {:unsafe_path, _}} = Transcripts.extract(up, dest)
      assert File.ls!(dest) == []
    end

    test "will not write through a symlink already at sessions/ in the destination", %{
      tmp_dir: tmp,
      dest: dest
    } do
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(dest, "sessions"))

      assert {:error, {:unsafe_destination, _}} =
               Transcripts.extract(tar!(tmp, [{@rollout, "x\n"}]), dest)

      assert File.ls!(outside) == []
    end

    test "pack/2 takes sessions/ rollouts (not links, not the login) and extract/2 takes them back",
         %{tmp_dir: tmp, dest: dest} do
      src = Path.join(tmp, "node-config")
      File.mkdir_p!(Path.join(src, "sessions/2026/11/19"))
      File.write!(Path.join(src, @rollout), rollout_body())
      File.write!(Path.join(src, "sessions/2026/11/19/notes.txt"), "no")
      File.write!(Path.join(src, "auth.json"), "RT-SECRET")
      File.ln_s!("/etc/passwd", Path.join(src, "sessions/2026/11/19/link.jsonl"))

      out = Path.join(tmp, "out.tar.gz")
      assert {:ok, %{files: 1}} = Pack.pack(src, out)
      assert {:ok, %{files: 1, skipped: []}} = Transcripts.extract(out, dest)
      assert File.read!(Path.join(dest, @rollout)) == rollout_body()
      refute File.exists?(Path.join(dest, "auth.json"))
    end

    test "usage is read from the extracted rollouts, where the local readers look", %{
      tmp_dir: tmp,
      dest: dest
    } do
      src = Path.join(tmp, "node-config")
      File.mkdir_p!(Path.join(src, "sessions/2026/11/19"))
      File.write!(Path.join(src, @rollout), rollout_body())

      out = Path.join(tmp, "out.tar.gz")
      assert {:ok, %{files: 1}} = Pack.pack(src, out)
      assert {:ok, %{files: 1}} = Transcripts.extract(out, dest)

      assert {:ok, path} = Wardmast.Usage.CodexSessionFile.locate(dest, "thread1")
      assert path == Path.join(dest, @rollout)

      assert {:ok, %{tokens_in: 1200, tokens_out: 340}} =
               Wardmast.Usage.CodexSessionFile.usage_for(dest, "thread1")
    end

    test "a Claude upload is unchanged: projects/ and sessions/ side by side", %{
      tmp_dir: tmp,
      dest: dest
    } do
      tar = tar!(tmp, [{"projects/p/s.jsonl", "a\n"}, {@rollout, "b\n"}])
      assert {:ok, %{files: 2}} = Transcripts.extract(tar, dest)
    end
  end
end
