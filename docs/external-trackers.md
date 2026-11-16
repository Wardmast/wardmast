# External trackers

A workspace's `tracker` block binds it to an external tracker (`github`, `gitlab`,
`jira`, `linear`, `shortcut`, or `none`):

    "tracker": {"type": "github", "config": {"owner": "acme", "repo": "tonic",
                                              "credentials_ref": "secret:github_token"}}

## GitHub Issues

Every tracker call (create, field sync, lifecycle transitions, close, claim, list)
authenticates with one token. Which token depends on the repo's credential
(`git_credentials.repos.<repo>`, see `docs/git-credentials.md`).

### With a GitHub App: `github_token` is optional

When the repo's `git_credentials` entry is a `github_app`, the tracker uses the
App's **installation token**, the same one the merger opens PRs with. It is minted
for the tracker's own `owner/repo` and carries only Issues **write**, Pull requests
**write** and Metadata **read** (no Contents, no Actions). It is cached for 30
minutes and minted again after that. The repo is the one the call is about
(`tracker.config.repos.<repo>` override), else the entry the tracker's `owner/repo`
matches (`acme/tonic` finds `repos.tonic`).

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

All of them go through `Arbiter.Trackers.GitHub.Config.resolve/0`:

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
