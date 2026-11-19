defmodule Wardmast.Mergers.Github.RepoResolverTest do
  use ExUnit.Case, async: true

  alias Wardmast.Mergers.Github.{Error, RepoResolver}

  describe "parse/1" do
    test "parses an SSH remote with .git suffix" do
      assert {:ok, {"acme-corp", "apex_server"}} =
               RepoResolver.parse("git@github.com:acme-corp/apex_server.git")
    end

    test "parses an SSH remote without .git suffix" do
      assert {:ok, {"octo", "widget"}} =
               RepoResolver.parse("git@github.com:octo/widget")
    end

    test "parses an HTTPS remote with .git suffix" do
      assert {:ok, {"acme-corp", "apex-client"}} =
               RepoResolver.parse("https://github.com/acme-corp/apex-client.git")
    end

    test "parses an HTTPS remote without .git suffix" do
      assert {:ok, {"ryanrborn", "arbiter"}} =
               RepoResolver.parse("https://github.com/ryanrborn/arbiter")
    end

    test "parses an HTTPS remote with trailing slash" do
      assert {:ok, {"ryanrborn", "arbiter"}} =
               RepoResolver.parse("https://github.com/ryanrborn/arbiter/")
    end

    test "tolerates Enterprise GitHub hosts" do
      assert {:ok, {"acme", "apex_server"}} =
               RepoResolver.parse("git@github.example.com:acme/apex_server.git")

      assert {:ok, {"acme", "apex_server"}} =
               RepoResolver.parse("https://github.example.com/acme/apex_server.git")
    end

    test "parses a GitLab origin (host is not constrained to github.com)" do
      assert {:ok, {"emricare", "tonic"}} =
               RepoResolver.parse("git@gitlab.com:emricare/tonic.git")

      assert {:ok, {"emricare", "tonic_device"}} =
               RepoResolver.parse("https://gitlab.com/emricare/tonic_device.git")
    end

    test "rejects garbage" do
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.parse("not a url")
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.parse("")
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.parse("https://github.com/")

      assert {:error, %Error{kind: :config_missing}} =
               RepoResolver.parse("https://github.com/only-one-segment")
    end
  end

  describe "parse/2 with nested: true (GitLab namespaces)" do
    test "keeps the full namespace path as the owner, SSH and HTTPS" do
      assert {:ok, {"group/sub", "project"}} =
               RepoResolver.parse("git@gitlab.internal:group/sub/project.git", nested: true)

      assert {:ok, {"group/sub/deeper", "project"}} =
               RepoResolver.parse("https://gitlab.internal/group/sub/deeper/project",
                 nested: true
               )

      assert {:ok, {"group/sub", "project"}} =
               RepoResolver.parse("https://gitlab.internal:8443/group/sub/project.git/",
                 nested: true
               )
    end

    test "a path-prefixed instance URL is not mistaken for a namespace only when told so" do
      assert {:ok, {"gitlab/group", "project"}} =
               RepoResolver.parse("https://h/gitlab/group/project.git", nested: true)
    end

    test "two-segment remotes parse the same as without nested" do
      assert {:ok, {"emricare", "tonic"}} =
               RepoResolver.parse("git@gitlab.com:emricare/tonic.git", nested: true)
    end

    test "without nested: true, three segments stay rejected (GitHub parsing unchanged)" do
      assert {:error, %Error{kind: :config_missing}} =
               RepoResolver.parse("https://github.com/a/b/c.git")

      assert {:error, %Error{kind: :config_missing}} =
               RepoResolver.parse("git@github.com:a/b/c.git")
    end

    test "rejects a bare host and a single segment" do
      assert {:error, _} = RepoResolver.parse("https://gitlab.internal/project", nested: true)
      assert {:error, _} = RepoResolver.parse("not a url", nested: true)
    end
  end

  describe "from_remote/1" do
    setup do
      # A local bare git repo with a configured `origin` remote is the
      # simplest way to exercise `git remote get-url origin` without hitting
      # the network. We create one in a tmp dir per test.
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "arbiter_repo_resolver_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)

      {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch=main", path])

      on_exit(fn -> File.rm_rf!(path) end)

      {:ok, path: path}
    end

    test "reads {owner, repo} from origin", %{path: path} do
      {_, 0} =
        System.cmd("git", [
          "-C",
          path,
          "remote",
          "add",
          "origin",
          "git@github.com:acme-corp/apex_server.git"
        ])

      assert {:ok, {"acme-corp", "apex_server"}} = RepoResolver.from_remote(path)
    end

    test "returns a config_missing error when origin is missing", %{path: path} do
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote(path)
    end

    test "returns a config_missing error when path is not a git checkout" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "arbiter_no_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote(path)
    end

    test "returns a config_missing error for empty / nil repo_path" do
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote("")
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote(nil)
    end
  end
end
