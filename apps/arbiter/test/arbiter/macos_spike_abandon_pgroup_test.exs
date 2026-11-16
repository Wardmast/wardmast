defmodule Arbiter.MacosSpikeAbandonPgroupTest do
  @moduledoc """
  Verifies `scripts/macos-spike/probe-abandon-pgroup.sh` against a fake
  `launchctl` that implements launchd's `AbandonProcessGroup` process-group
  semantics using POSIX sessions/process groups:

  - Every bootstrapped job starts as a session and process-group leader
    (`setsid`).
  - On `bootout`, `AbandonProcessGroup=false` sends `SIGTERM` to the entire
    process group (`-pgid`), while `AbandonProcessGroup=true` sends `SIGTERM`
    only to the job leader (`pid`).

  A child that daemonises into its own session (like `tmux`) escapes the
  control's process-group kill and makes the probe inconclusive; a child kept
  in the job's process group dies in the control (`false`) and survives when
  abandoned (`true`).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @probe Path.join(@root, "scripts/macos-spike/probe-abandon-pgroup.sh")

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "abandon-pgroup-test-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(tmp, "bin")
    state_dir = Path.join(tmp, "state")
    results_dir = Path.join(tmp, "results")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(state_dir)
    File.mkdir_p!(results_dir)

    write_executable!(Path.join(bin_dir, "sleep"), ~S"""
    #!/bin/sh
    if [ "${1:-}" = "3" ]; then
      exec /bin/sleep 0.1
    fi
    exec /bin/sleep "$@"
    """)

    write_executable!(Path.join(bin_dir, "launchctl"), ~S"""
    #!/usr/bin/env perl
    use strict;
    use warnings;
    use POSIX qw(setsid);

    my $state_dir = $ENV{FAKE_LAUNCHCTL_STATE_DIR} or die "missing FAKE_LAUNCHCTL_STATE_DIR";
    my $mode = $ENV{FAKE_LAUNCHCTL_MODE} || "normal";
    my $subcmd = shift @ARGV || "";

    if ($subcmd eq "bootstrap") {
      exit 1 if $mode eq "bootstrap_fail";
      my ($domain, $plist) = @ARGV;
      open my $fh, "<", $plist or die "open $plist: $!";
      local $/;
      my $xml = <$fh>;
      close $fh;

      my ($label) = $xml =~ m{<key>Label</key>\s*<string>([^<]+)</string>}s
        or die "missing Label in $plist";
      my ($abandon) = $xml =~ m{<key>AbandonProcessGroup</key>\s*<(true|false)\s*/>}s
        or die "missing AbandonProcessGroup in $plist";
      my ($arr) = $xml =~ m{<key>ProgramArguments</key>\s*<array>(.*?)</array>}s
        or die "missing ProgramArguments in $plist";

      my @args;
      while ($arr =~ m{<string>(.*?)</string>}sg) {
        my $s = $1;
        $s =~ s/&lt;/</g;
        $s =~ s/&gt;/>/g;
        $s =~ s/&quot;/"/g;
        $s =~ s/&apos;/'/g;
        $s =~ s/&amp;/&/g;
        push @args, $s;
      }

      my $pid = fork();
      die "fork failed" unless defined $pid;
      if ($pid == 0) {
        setsid() or die "setsid: $!";
        open STDIN, "</dev/null";
        open STDOUT, ">/dev/null";
        open STDERR, ">/dev/null";
        exec @args or die "exec failed: $!";
      }

      open my $sfh, ">", "$state_dir/$label.state" or die "write state: $!";
      print $sfh "$pid $abandon\n";
      close $sfh;

      open my $afh, ">>", "$state_dir/pgids.list" or die "write pgids: $!";
      print $afh "$pid\n";
      close $afh;
      exit 0;
    } elsif ($subcmd eq "bootout") {
      my ($spec) = @ARGV;
      my ($label) = $spec =~ m{([^/]+)\z};
      my $sfile = "$state_dir/$label.state";
      exit 1 unless -f $sfile;

      open my $sfh, "<", $sfile or die "read state: $!";
      my $line = <$sfh>;
      close $sfh;
      chomp $line;
      my ($pid, $abandon) = split /\s+/, $line;

      if ($mode eq "never_kill_pgroup") {
        kill "TERM", $pid;
      } elsif ($mode eq "always_kill_pgroup") {
        kill "TERM", -$pid;
      } elsif ($mode eq "invert_pgroup") {
        if ($abandon eq "true") {
          kill "TERM", -$pid;
        } else {
          kill "TERM", $pid;
        }
      } elsif ($abandon eq "true") {
        kill "TERM", $pid;
      } else {
        kill "TERM", -$pid;
      }
      unlink $sfile;
      exit 0;
    }

    exit 1;
    """)

    on_exit(fn ->
      pgids_file = Path.join(state_dir, "pgids.list")

      if File.exists?(pgids_file) do
        pgids_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.each(fn pid_str ->
          case Integer.parse(pid_str) do
            {pgid, ""} when pgid > 1 ->
              System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)

            _ ->
              :ok
          end
        end)
      end

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, bin_dir: bin_dir, state_dir: state_dir, results_dir: results_dir}
  end

  defp write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp run_probe(ctx, mode \\ "normal") do
    env = [
      {"PATH", "#{ctx.bin_dir}:#{System.get_env("PATH")}"},
      {"FAKE_LAUNCHCTL_STATE_DIR", ctx.state_dir},
      {"FAKE_LAUNCHCTL_MODE", mode},
      {"RESULTS_DIR", ctx.results_dir},
      {"RUNNER_TEMP", ctx.tmp}
    ]

    {output, status} = System.cmd("bash", [@probe], env: env, stderr_to_stdout: true)
    result = ctx.results_dir |> Path.join("abandon-pgroup.result") |> File.read!() |> String.trim()
    {status, result, output}
  end

  test "records PASS when same-pgroup child survives AbandonProcessGroup=true and dies on false",
       ctx do
    {0, result, output} = run_probe(ctx, "normal")

    assert result =~ ~r/\APASS:.*true=survived.*false=killed/
    assert output =~ "AbandonProcessGroup=true  -> child survived"
    assert output =~ "AbandonProcessGroup=false -> child killed"

    pgids =
      ctx.state_dir
      |> Path.join("pgids.list")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(pgids) == 2

    for pgid <- pgids do
      assert output =~ ~r/\b\d+\s+#{pgid}\s+#{pgid}\s+sleep\b/
    end
  end

  test "records FAIL with observed states when control child survives (AbandonProcessGroup=false)",
       ctx do
    {0, result, _output} = run_probe(ctx, "never_kill_pgroup")

    assert result =~ ~r/\AFAIL:.*true=survived.*false=survived/
  end

  test "records FAIL with observed states when abandoned child is killed (AbandonProcessGroup=true)",
       ctx do
    {0, result, _output} = run_probe(ctx, "always_kill_pgroup")

    assert result =~ ~r/\AFAIL:.*true=killed.*false=killed/
  end

  test "records FAIL with observed states when abandoned child dies and control survives",
       ctx do
    {0, result, _output} = run_probe(ctx, "invert_pgroup")

    assert result =~ ~r/\AFAIL:.*true=killed.*false=survived/
  end

  test "records FAIL with observed states when launchctl bootstrap fails", ctx do
    {0, result, _output} = run_probe(ctx, "bootstrap_fail")

    assert result =~ ~r/\AFAIL:.*true=error.*false=error/
  end
end
