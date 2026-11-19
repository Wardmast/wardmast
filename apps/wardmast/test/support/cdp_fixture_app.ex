defmodule Wardmast.Test.CdpFixtureApp do
  @moduledoc """
  A tiny login-gated web app for the CDP shooter tests (`Shooter.Cdp`), served by Bandit on a
  loopback port.

    * `GET /login` is a sign-in form (`#email`, `#password`, `#go`); `POST /login` with
      `admin@example.com` / `right` sets a session cookie and redirects to `/home`. Anything else
      redirects back to `/login`. `?stay=1` makes a good login redirect to `/login?ok=1` instead,
      so the browser never leaves the login path.
    * `GET /home` needs the cookie (else redirects to `/login`) and shows the date it is rendered
      with; `#open` reveals `#panel`; `#stamp` carries a time-dependent value to hide.
    * `GET /tall` is a page of 3000 px. `GET /boom` answers 500. `GET /expired` bounces to
      `/login` even with the cookie (a session that does not hold). `GET /outside` tries to load
      an image from a non-loopback host.
  """
  use Plug.Router

  plug(Plug.Parsers, parsers: [:urlencoded])
  plug(:match)
  plug(:dispatch)

  @page """
  <!doctype html><html><head><meta charset="utf-8"><title>fixture</title>
  <style>body{font:16px sans-serif;margin:16px}</style></head><body>%BODY%</body></html>
  """

  defp html(conn, status \\ 200, body),
    do:
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(status, String.replace(@page, "%BODY%", body))

  defp logged_in?(conn),
    do: conn |> fetch_cookies() |> Map.get(:req_cookies) |> Map.get("sid") == "good"

  defp redirect(conn, to), do: conn |> put_resp_header("location", to) |> send_resp(302, "")

  get "/login" do
    html(conn, """
    <h1 id="title">Sign in</h1>
    <form method="post" action="/login#{if conn.query_string == "stay=1", do: "?stay=1", else: ""}">
      <input id="email" name="email"><input id="password" name="password" type="password">
      <button id="go">Sign in</button>
    </form>
    """)
  end

  post "/login" do
    stay = conn.query_string == "stay=1"

    case conn.body_params do
      %{"email" => "admin@example.com", "password" => "right"} ->
        conn
        |> put_resp_cookie("sid", "good", http_only: true)
        |> redirect(if stay, do: "/login?ok=1", else: "/home")

      _ ->
        redirect(conn, "/login")
    end
  end

  get "/home" do
    if logged_in?(conn) do
      html(conn, """
      <h1 id="title">Dashboard</h1>
      <p id="stamp">rendered</p>
      <p id="theme"></p>
      <button id="open" onclick="document.getElementById('panel').hidden = false">Open</button>
      <div id="panel" hidden style="border:1px solid #888;padding:8px">Panel body</div>
      <script>
        document.getElementById('stamp').textContent = new Date().toISOString();
        document.getElementById('theme').textContent =
          (localStorage.getItem('theme') || 'none') + '/' +
          (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') + '/' +
          Intl.DateTimeFormat().resolvedOptions().timeZone + '/' + navigator.language;
      </script>
      """)
    else
      redirect(conn, "/login")
    end
  end

  get "/expired" do
    redirect(conn, "/login")
  end

  get "/tall" do
    if logged_in?(conn),
      do: html(conn, ~s(<h1>Tall</h1><div style="height:3000px;background:#eef">tall</div>)),
      else: redirect(conn, "/login")
  end

  get "/boom" do
    send_resp(conn, 500, "boom")
  end

  get "/outside" do
    html(conn, ~s(<h1>Out</h1><img src="http://203.0.113.7/pixel.png">))
  end

  match _ do
    send_resp(conn, 404, "nope")
  end
end
