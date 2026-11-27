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
    * `GET /reports` shows `#picker` (\"Select an Organization\") until `GET /switch-tenant/:id?return_to=`
      set the tenant cookie; then it shows `#reports`.
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
    #{if conn.query_string == "error=1", do: ~s(<div role="alert">Invalid email or password<br>second line</div>), else: ""}
    <form method="post" action="/login#{if conn.query_string == "stay=1", do: "?stay=1", else: ""}">
      <input id="email" name="email"><input id="password" name="password" type="password">
      <button id="go">Sign in</button>
    </form>
    """)
  end

  # A LiveView-style sign-in: the socket "connects" 600 ms after load, wiping whatever was typed
  # and only then adding `phx-connected`; a submit before that is swallowed.
  get "/lv-login" do
    html(conn, """
    <h1 id="title">Sign in</h1>
    <div data-phx-main id="main">
    <form id="lvform" method="post" action="/login">
      <input id="email" name="email"><input id="password" name="password" type="password">
      <button id="go">Sign in</button>
    </form></div>
    <script>
      var connected = false;
      document.getElementById('lvform').addEventListener('submit', function (e) {
        if (!connected) e.preventDefault();
      });
      setTimeout(function () {
        document.getElementById('lvform').reset();
        connected = true;
        document.getElementById('main').classList.add('phx-connected');
      }, 600);
    </script>
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
        redirect(conn, "/login?error=1")
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

  # A multi-tenant persona: /reports shows a tenant picker until /switch-tenant/:id chose one.
  get "/switch-tenant/:id" do
    if logged_in?(conn) do
      to = Map.get(fetch_query_params(conn).query_params, "return_to", "/home")
      conn |> put_resp_cookie("tenant", id) |> redirect(to)
    else
      redirect(conn, "/login")
    end
  end

  # A transient network failure: the first three requests for an id get no response at all (the
  # handler dies, the socket closes: the browser's ERR_EMPTY_RESPONSE; Chrome itself retries a
  # dropped request once), later ones switch the tenant.
  get "/flaky-switch/:id" do
    key = {__MODULE__, :flaky, id}

    if :persistent_term.get(key, 0) >= 3 do
      conn |> put_resp_cookie("tenant", id) |> redirect("/reports")
    else
      :persistent_term.put(key, :persistent_term.get(key, 0) + 1)
      {_adapter, %{transport: %{socket: socket}}} = conn.adapter
      ThousandIsland.Socket.close(socket)
      Process.exit(self(), :kill)
      conn
    end
  end

  get "/reports" do
    cond do
      not logged_in?(conn) ->
        redirect(conn, "/login")

      tenant = fetch_cookies(conn).req_cookies["tenant"] ->
        html(conn, ~s(<h1 id="reports">Reports for #{tenant}</h1>))

      true ->
        html(conn, ~s(<h1 id="picker">Select an Organization</h1>))
    end
  end

  get "/moved" do
    redirect(conn, "/home")
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
