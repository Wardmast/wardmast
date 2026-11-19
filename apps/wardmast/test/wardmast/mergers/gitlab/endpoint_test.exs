defmodule Wardmast.Mergers.Gitlab.EndpointTest do
  @moduledoc """
  Self-managed GitLab (#1521): an optional `base_url` / `api_url` (scheme + host +
  optional path prefix, default `https://<host>`) and an optional `ca_cacertfile`,
  shared by the merger, tracker and bot-credential clients.
  """
  use ExUnit.Case, async: false

  alias Wardmast.Http.Client
  alias Wardmast.Mergers.Gitlab, as: Merger
  alias Wardmast.Mergers.Gitlab.{Config, Endpoint}
  alias Wardmast.Trackers.Gitlab, as: Tracker
  alias Wardmast.Trackers.Gitlab.Config, as: TrackerConfig

  @env_var "GTE_GITLAB_ENDPOINT_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "tok")

    on_exit(fn ->
      Config.clear()
      TrackerConfig.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp raw(extra \\ %{}) do
    Map.merge(
      %{"host" => "gitlab.internal", "project_id" => 7, "credentials_ref" => "env:#{@env_var}"},
      extra
    )
  end

  describe "Endpoint" do
    test "defaults to https://<host>" do
      assert Endpoint.base_url(%{host: "gitlab.com"}) == "https://gitlab.com"
      assert Endpoint.api_url(%{host: "gitlab.com"}) == "https://gitlab.com/api/v4"
      assert Endpoint.connect_options(%{host: "gitlab.com"}) == []
    end

    test "an explicit base_url wins and is normalised" do
      cfg = %{host: "gitlab.internal", base_url: "http://gitlab.internal:8080/gitlab/"}
      assert Endpoint.base_url(cfg) == "http://gitlab.internal:8080/gitlab"
      assert Endpoint.api_url(cfg) == "http://gitlab.internal:8080/gitlab/api/v4"
    end

    test "from_raw accepts base_url, or api_url with or without the /api/v4 suffix" do
      assert Endpoint.from_raw(%{"base_url" => "http://a/g/"}) == "http://a/g"
      assert Endpoint.from_raw(%{"api_url" => "https://a/g/api/v4"}) == "https://a/g"
      assert Endpoint.from_raw(%{"api_url" => "https://a/api/v4/"}) == "https://a"
      assert Endpoint.from_raw(%{"api_url" => "https://a"}) == "https://a"
      assert Endpoint.from_raw(%{"base_url" => ""}) == nil
      assert Endpoint.from_raw(%{}) == nil
    end

    test "connect_options carries ca_cacertfile as the TLS cacertfile" do
      assert Endpoint.connect_options(%{ca_cacertfile: "/etc/ca.pem"}) ==
               [transport_opts: [cacertfile: "/etc/ca.pem"]]

      assert Endpoint.connect_options(%{ca_cacertfile: ""}) == []
      assert Endpoint.connect_options(%{ca_cacertfile: nil}) == []
    end
  end

  describe "merger" do
    test "config exposes base_url and ca_cacertfile, defaulting to nil (existing configs unchanged)" do
      Config.put_active(raw())
      assert {:ok, %{base_url: nil, ca_cacertfile: nil}} = Config.resolve()

      Config.put_active(raw(%{"base_url" => "http://gl:81/x", "ca_cacertfile" => "/ca.pem"}))
      assert {:ok, %{base_url: "http://gl:81/x", ca_cacertfile: "/ca.pem"}} = Config.resolve()
    end

    test "client uses https://<host> by default with no TLS options" do
      Config.put_active(raw())
      {:ok, cfg} = Config.resolve()
      client = Merger.client(cfg)
      assert client.base_url == "https://gitlab.internal/api/v4/projects/7"
      opts = Client.build_opts(client, :get, "/x", [])
      refute Keyword.has_key?(opts, :connect_options)
    end

    test "client uses base_url (scheme + host + path prefix) and the CA bundle" do
      Config.put_active(raw(%{"base_url" => "http://gl:81/x", "ca_cacertfile" => "/ca.pem"}))
      {:ok, cfg} = Config.resolve()
      client = Merger.client(cfg)
      assert client.base_url == "http://gl:81/x/api/v4/projects/7"

      assert Client.build_opts(client, :get, "/x", [])[:connect_options] ==
               [transport_opts: [cacertfile: "/ca.pem"]]

      root = Merger.root_client(cfg)
      assert root.base_url == "http://gl:81/x/api/v4"
      assert Client.build_opts(root, :get, "/user", [])[:connect_options] != nil
    end

    test "an explicit connect_options in req_opts still wins over the client's" do
      Config.put_active(raw(%{"ca_cacertfile" => "/ca.pem"}))
      {:ok, cfg} = Config.resolve()

      opts = Client.build_opts(Merger.client(cfg), :get, "/x", connect_options: [timeout: 1])
      assert opts[:connect_options] == [timeout: 1]
    end

    test "link_for uses the base_url" do
      Config.put_active(raw(%{"base_url" => "http://gl:81/x", "project_id" => "g/s/p"}))
      assert Merger.link_for("g/s/p!3") == "http://gl:81/x/g/s/p/-/merge_requests/3"
    end
  end

  describe "tracker" do
    test "config defaults to nil" do
      TrackerConfig.put_active(raw())
      assert {:ok, %{base_url: nil, ca_cacertfile: nil}} = TrackerConfig.resolve()
    end

    test "clients use base_url and the CA bundle" do
      TrackerConfig.put_active(
        raw(%{"base_url" => "http://gl:81/x", "ca_cacertfile" => "/ca.pem", "project_id" => "7"})
      )

      {:ok, cfg} = TrackerConfig.resolve()
      client = Tracker.project_client(cfg)
      assert client.base_url == "http://gl:81/x/api/v4/projects/7"

      assert Client.build_opts(client, :get, "/x", [])[:connect_options] ==
               [transport_opts: [cacertfile: "/ca.pem"]]

      assert Tracker.root_client(cfg).base_url == "http://gl:81/x/api/v4"
    end

    test "default client is https://<host> with no TLS options" do
      TrackerConfig.put_active(raw(%{"project_id" => "7"}))
      {:ok, cfg} = TrackerConfig.resolve()
      client = Tracker.project_client(cfg)
      assert client.base_url == "https://gitlab.internal/api/v4/projects/7"
      refute Keyword.has_key?(Client.build_opts(client, :get, "/x", []), :connect_options)
    end

    test "link_for uses the base_url" do
      TrackerConfig.put_active(raw(%{"base_url" => "http://gl:81/x", "project_id" => "g/p"}))
      assert Tracker.link_for("5") == "http://gl:81/x/g/p/-/issues/5"
    end
  end
end
