defmodule WardmastCli.Cmd.SupportTest do
  @moduledoc "`arb support bundle` writes the server's redacted diagnostics archive to disk."
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.Support

  test "bundle writes the archive to --out" do
    out = Path.join(System.tmp_dir!(), "bundle-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(out) end)

    stub_post(
      "/api/support/bundle",
      %{"filename" => "arb-support-bundle-x.tar.gz", "data_base64" => Base.encode64("TARBYTES")},
      200
    )

    {stdout, _err, code} = capture(fn -> Support.run(["bundle", "--out", out]) end)

    assert code == 0
    assert File.read!(out) == "TARBYTES"
    assert stdout =~ out
  end

  test "bundle sends the doctor check results as a client file" do
    out = Path.join(System.tmp_dir!(), "bundle-226.tar.gz")
    on_exit(fn -> File.rm(out) end)
    on_exit(fn -> Application.delete_env(:wardmast_cli, :support_doctor_checks) end)
    parent = self()

    Application.put_env(:wardmast_cli, :support_doctor_checks, fn ->
      [
        %WardmastCli.Cmd.Doctor.Checks.Result{
          id: "demo",
          group: :core,
          status: :warn,
          name: "demo-check-title",
          detail: "demo-check-message"
        }
      ]
    end)

    stub_routes([
      {{"post", "/api/support/bundle"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(parent, {:body, Jason.decode!(raw)})

         conn
         |> Plug.Conn.put_resp_content_type("application/json")
         |> Plug.Conn.send_resp(
           200,
           Jason.encode!(%{"filename" => "x.tar.gz", "data_base64" => Base.encode64("T")})
         )
       end}
    ])

    {_stdout, _err, 0} = capture(fn -> Support.run(["bundle", "--out", out]) end)

    assert_received {:body, %{"extra_files" => %{"doctor-checks.txt" => text}}}
    assert text =~ "demo-check-title"
  end

  test "unknown subcommand dies" do
    {_out, err, code} = capture(fn -> Support.run(["nope"]) end)
    assert code != 0
    assert err =~ "bundle"
  end
end
