# External trackers

A workspace's `tracker` block binds it to an external tracker (`github`, `gitlab`,
`jira`, `linear`, `shortcut`, or `none`):

    "tracker": {"type": "github", "config": {"owner": "acme", "repo": "app",
                                              "credentials_ref": "secret:github_token"}}

## Entering tracker credentials from the dashboard

`/workspaces/:id` → **Secrets** and **Tracker** cover the whole credential
lifecycle without `arb` or a config file. Credentials live in the workspace's
encrypted secret vault (`docs/secrets-at-rest.md`) and the tracker points at one
with `credentials_ref: "secret:<key>"`.

**Secrets are write-only.** *Set secret* stores a key and value; *Replace* on a
row overwrites the value of an existing key (the old value is never read back, so
the field starts empty); the trash button deletes it. After the write only the
key name is ever rendered, returned by `GET /api/workspaces/:id` (`secret_keys`)
or logged.

**Two ways to get a token into the vault:**

1. **OAuth device flow (GitHub and GitLab).** On the Tracker pane choose
   *Authorize*. Wardmast shows a one-time code and a URL; open the URL, enter the
   code and approve. The page polls (honouring the provider's `interval` and any
   `slow_down`) until you approve, deny, or the code expires, then stores the
   token as `github_oauth_token` / `gitlab_oauth_token` and — only if the
   tracker has no `credentials_ref` yet — points it at that secret. Denied,
   expired and provider errors are shown and nothing is stored; *Cancel* stops
   polling.
2. **Paste a personal access token (every tracker, and the fallback for the
   above).** *Set secret* with the PAT (GitHub, GitLab), API token (Shortcut,
   Jira, Linear), then pick `secret:<key>` in the tracker's *Credentials* select
   and save.

Device flow needs an OAuth app's **client ID** (public, no client secret). Wardmast
ships none: register one (GitHub: an OAuth app with *Enable Device Flow*, scope
`repo`; GitLab 17.2+: a non-confidential application with the `api` scope, on the
tracker's `host`), then either type the ID into the Authorize box or set
`WARDMAST_GITHUB_OAUTH_CLIENT_ID` / `WARDMAST_GITLAB_OAUTH_CLIENT_ID` on the
server. GitHub Enterprise is detected from `tracker.config.base_url`; GitLab uses
`tracker.config.host`. The GitLab tracker sends the token as both `PRIVATE-TOKEN`
and `Authorization: Bearer`, because a device-flow (OAuth) token is only accepted
as Bearer.

**Test connection.** The button next to *Save tracker config* runs the adapter's
authenticated identity read (`GET /user`, a `viewer` query, …) with the form's
*unsaved* values over the saved config, and reports `Connected as <identity>` or
the tracker's own error text. Stored secret values are scrubbed from that text
first. Testing never saves the form.

## GitHub Issues

Every tracker call (create, field sync, lifecycle transitions, close, claim, list)
authenticates with one token. Which token depends on the repo's credential
(`git_credentials.repos.<repo>`, see `docs/git-credentials.md`).

### With a GitHub App: `github_token` is optional

When the repo's `git_credentials` entry is a `github_app`, the tracker uses the
App's **installation token**, the same one the merger opens PRs with. It is minted
for the tracker's own `owner/repo` and carries only Issues **write**, Pull requests
**write** and Metadata **read** (no Contents, no Actions). It is cached for 30
minutes and minted again after that. The `git_credentials` entry is found by **repo
key** (the `repo_paths` key, e.g. `arbiter`), which need not equal the forge repo
name. In order:

1. the repo the call is about: the **ticket's repo** (`issue.repo`) wherever a
   ticket is in hand (`Trackers.prepare_with_repo/3`), which also applies the
   `tracker.config.repos.<repo>` override;
2. an entry keyed by the tracker's `owner/repo` slug (`acme/app` finds
   `repos.app`);
3. a repo key whose forge config targets that slug: the repo's effective
   `merge.config` `owner`/`repo` (workspace-level, deep-merged with
   `merge.repos.<key>.config`) or a `tracker.config.repos.<key>` `owner`/`repo`.
   So key `arbiter` with tracker slug `wardmast/wardmast` resolves the App for
   calls that only know the workspace (claim, list, tracker context fetch).


A personal token (`tracker.config.credentials_ref`, a.k.a. the `github_token`
secret) is therefore **optional** for a repo with a GitHub App. Without it nothing
is lost except a personal identity (below). A repo with no `github_app` entry
keeps using `credentials_ref`, exactly as before, and there it is required.

A `github_app` entry whose token cannot be minted (the private key secret is gone,
the installation is gone, GitHub refuses) is an **error**, never a silent fallback
to the personal token: a stale personal token that GitHub rejects with
`Resource not accessible by personal access token` is what this replaces, and a
quiet fallback would hide the real problem.

The App's calls are counted in the **installation's** rate-limit pool
(`{:installation, <installation_id>}` in the limiter's stats), not the operator
account's: see `docs/github-request-budget.md`.

### Claiming without a personal identity

"Issues assigned to the workspace user" (`tracker_list_issues`, `arb ticket list
--tracker`, the `tracker_sync` auto-claim, `tracker_claim`'s assignment check) needs
a person: a GitHub App cannot be an assignee. So:

* **With a personal `credentials_ref` as well**, nothing changes: `GET /user` names
  the viewer (with the personal token) and issues are listed by assignee (with the
  App token).
* **Without one**, the claim set is the open issues carrying the label
  `tracker.config.claim_label` (default `arbiter`). `current_user` is
  `label:<name>`; an issue with that label and no human assignee counts as claimed
  by this workspace, one a person holds is theirs, an unlabelled issue is nobody's
  (claim it with `force`). Asking the tracker to *assign* is skipped.

The list and sync responses say so: `tracker_list_issues` and `tracker_sync` (and
their REST twins) carry `filter: {mode: "label", label: "<name>", note: "..."}`
when the label stands in for the assignee, and no `filter` key otherwise.

    arb config set tracker.config.claim_label arbiter

### Call sites

All of them go through `Wardmast.Trackers.GitHub.Config.resolve/0`:

| Operation | Function | Token |
| --- | --- | --- |
| create issue | `create/1` | App, else `credentials_ref` |
| read issue | `fetch/1`, `list_transitions/1`, `list_comments/1`, `search_by_title/1` | same |
| update fields | `update_fields/2` | same |
| lifecycle transition, close | `transition/2` | same |
| comment, remote link | `post_comment/2`, `add_comment/2`, `add_remote_link/3`, `signal_claim/3` | same |
| list claimable | `list_open/1`, `list_assigned_open_issues/1` | same (filter by assignee or label) |
| viewer identity | `viewer_login/0`, `current_user/0` | personal `credentials_ref` only; with none, the claim label |
| assign | `assign_user/2` | same as the call site (skipped for a label identity) |

### Which repo each `prepare` call resolves the credential from

| Call site | Repo used |
| --- | --- |
| `Tasks.Issue.Changes.SyncFields` (title/description edit) | `issue.repo` |
| `Tasks.Issue.Changes.SyncTracker` | `issue.repo` |
| `Trackers.Sync` lifecycle (`do_lifecycle`), close (`do_close_and_verify`), `retry_lifecycle`, `sync` | `issue.repo` |
| `Workflows.Work` (close) | `task.repo` |
| `Workflows.MergeQueue` (MR remote link) | the queue item's repo |
| `Tasks.Issue.Changes.CreateUpstream` (`Trackers.create_for_workspace/3`) | `issue.repo` |
| `Tasks.Claim`, `Trackers.list_open/2`, `create_ticket_only/2`, `search_*`, tracker-context fetches (`Worker.Dispatch`, `Reviews.ExternalReview`) | no ticket yet: the slug mapping above |
