# agy on a service-account key: operator runbook

**Task:** bd-b2t0kw · **Status:** shipped in code; not yet run against a real Google
Cloud project (see [What was and was not verified](#what-was-and-was-not-verified)).

agy (the Antigravity CLI, provider `gemini`) normally keeps its Google login in the
desktop keyring. A container or a cluster pod has no keyring, so there agy signs in with a
**Google Cloud service-account key** instead: Application Default Credentials (ADC). This
runbook creates that key and registers it with Wardmast. After that:

* an agy worker under `sandbox.backend: podman` (or `auto` on a cluster node) runs in a
  container with the key mounted as a file;
* a cluster node (the in-cluster controller) advertises `caps.agy`, so placement can send
  agy runs to it.

A workspace whose antigravity account has no key keeps running agy exactly as before: on
the primary, in the bwrap jail, on the keyring login.

## How agy uses the key (measured on agy 1.5.9)

These facts come from agy 1.5.9 itself, the version pinned in the worker image
(`Wardmast.Worker.CliFetcher`). They were measured offline: in a bwrap sandbox with no
network, the keyring and the operator's home masked, a fake key whose `token_uri` pointed
at a local stand-in, and a logging proxy as `HTTPS_PROXY`.

| Question | Answer |
|---|---|
| What switches agy to the key? | `AGY_ADC_AUTH`, a boolean. `true`/`1` signs in with ADC; `false`/`0`/unset falls back to the consumer Google OAuth sign-in |
| Where does it read the key? | Go's standard ADC chain: the file named by `GOOGLE_APPLICATION_CREDENTIALS`, then `$HOME/.config/gcloud/application_default_credentials.json`, then the metadata server |
| How does it use it? | A JWT signed with the key is exchanged for an access token at the key's `token_uri` (`https://oauth2.googleapis.com/token`). Scopes requested: `cloud-platform`, `userinfo.email`, `userinfo.profile`, `cclog`, `experimentsandconfigs` |
| Which Google Cloud project? | `GOOGLE_CLOUD_QUOTA_PROJECT` if set, else the key's own `project_id`. `GOOGLE_CLOUD_PROJECT` does **not** change it. Wardmast sets neither, so it is the key's project |
| Which location? | `GOOGLE_CLOUD_LOCATION`, default `global` (`aiplatform.googleapis.com`). A region such as `us-central1` makes it call `us-central1-aiplatform.googleapis.com`. Wardmast sets none, so it is `global` |
| What does it call? | Vertex AI: `POST https://aiplatform.googleapis.com/v1/projects/<project>/locations/global/publishers/google/models/<model>:streamGenerateContent` (the default model on 1.5.9 is `gemini-4-carbon`) |
| Which hosts? | `oauth2.googleapis.com`, `www.googleapis.com` (`/oauth2/v2/userinfo`; a failure there is not fatal), `aiplatform.googleapis.com`, `play.googleapis.com` (telemetry). These are the container's egress baseline |
| Does it need a keyring? | No: it logs "Using file-based token storage because no D-Bus session bus detected" and signs in |

So the key file is the only input. No project or location needs configuring beside it.

## 1. Create the service account and its key (Google Cloud)

Use a project you are willing to bill for Vertex AI. These are standard `gcloud` commands;
`PROJECT` is your project id.

```sh
PROJECT=my-agy-project
gcloud config set project "$PROJECT"

# 1. The API agy calls (Vertex AI). The token exchange needs no extra API.
gcloud services enable aiplatform.googleapis.com

# 2. A service account used only by Wardmast workers.
gcloud iam service-accounts create wardmast-agy \
  --display-name="Wardmast agy workers"
SA="wardmast-agy@${PROJECT}.iam.gserviceaccount.com"

# 3. Roles. Vertex AI User lets it call the Gemini models. Service Usage Consumer lets it
#    use the project as its quota project, which agy sends (the key's project_id).
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/aiplatform.user"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/serviceusage.serviceUsageConsumer"

# 4. The JSON key. Write it somewhere private, register it (step 2), then delete it.
umask 077
gcloud iam service-accounts keys create ./wardmast-agy-key.json --iam-account="$SA"
```

Notes:

* An organization policy may forbid key creation (`iam.disableServiceAccountKeyCreation`).
  An admin then has to exempt the project, or this design cannot be used there.
* Grant nothing broader: the key is readable by the worker it runs in (see
  [Threat model](#threat-model)), so its account should reach Vertex AI and nothing else.
* To use Claude models through agy, enable them for the project in Vertex AI Model
  Garden. agy only lists the models the project can use.
* Billing is Vertex AI's pay-as-you-go pricing on this project. Wardmast does not read a
  quota for it yet (the Antigravity quota surface is tied to the consumer login).

## 2. Register the key with Wardmast

The key belongs to an `antigravity` provider account. Use the account your workspaces
already route agy through, or create one:

```sh
arb account list --provider antigravity
arb account create antigravity workers --label "agy service account"   # if needed
arb account attach <workspace> antigravity antigravity:workers         # if needed
```

Then store the key. Pass the file, or `-` to read it from stdin; the command refuses a
key on the command line, where `ps` and the shell history would keep it:

```sh
arb account rotate antigravity:workers --kind service_account --secret-file ./wardmast-agy-key.json
# rotated service_account credential (fingerprint=...)
rm ./wardmast-agy-key.json
```

What the server does with it:

* checks it is a service-account key (`type`, `project_id`, `client_email`,
  `private_key`); a user login or a malformed file is refused with what is wrong, never
  with the key;
* stores it encrypted at rest (the same vault as every provider credential); the
  previous key of the account, if any, is retired;
* files it under `GOOGLE_APPLICATION_CREDENTIALS`. That is where a worker finds the key
  **file**: the key itself is never put in a worker's environment.

Rotating is the same command with the new file. To take the key out of service, park the
account (`arb account set antigravity:workers --disable`) or delete it, and delete the key
in Google Cloud (`gcloud iam service-accounts keys delete <key-id> --iam-account="$SA"`).

## 3. What a worker gets

| Where agy runs | The key | The env |
|---|---|---|
| A container on the primary (`sandbox.backend: podman`, or `auto` with `local_backend: podman`) | a `podman run --secret`, mounted read-only for the container user at `/run/secrets/agy-adc.json`; created from a 0600 file that is deleted at once, removed with the container and by the boot reaper | `AGY_ADC_AUTH=true`, `GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/agy-adc.json` |
| A cluster pod | the run spec's `secret_files`: the primary's `assign` → the controller's memory → the pod's `/boot` tar → `/run/arb/creds/agy-adc.json` on the pod's memory volume (0600) for the run's life. Never a Kubernetes object, never the pod spec | `AGY_ADC_AUTH=true`, `GOOGLE_APPLICATION_CREDENTIALS=/run/arb/creds/agy-adc.json` |
| The primary under bwrap (any workspace without a key) | none: agy uses the keyring login, as before | unchanged |

The container also gets its own `$HOME`, seeded with the generated permission posture
(`~/.gemini/antigravity-cli/settings.json`), the worker `GEMINI.md` and the run's MCP
config (`~/.gemini/config/mcp_config.json`). In a pod the MCP config, which holds a bearer
token agy reads literally (it does not expand environment variables in that file), sits
on the memory volume beside the key and is linked into the config dir.

## 4. Check it

* `arb account show antigravity:workers` lists a `service_account` credential (kind and
  fingerprint only).
* A workspace on `sandbox.backend: podman` with an agy pool is no longer held with
  "gemini: not supported by sandbox.backend podman".
* `GET /api/nodes` (what `arb node list` reads): each node has
  `"agy": {"ready": true, "missing": null}` once it advertises `caps.agy`. Otherwise
  `missing` says which half it lacks (`caps.agy_missing`):
  * `image`: no published worker image carries agy yet (`arbiter.cli-providers` lacks
    `gemini`). Publish one (any remote run of the repo, or the publisher's refresh).
  * `credential`: no enabled antigravity account attached to a workspace holds a key.
  The controller re-reads these facts every canary run (10 minutes) and its heartbeat
  carries them, so no restart is needed.
* An agy ticket with `worker.placement: prefer_remote` then runs on the node; its routing
  decision says `auto: <node> had a free slot -> podman`.

## Threat model

* **What the worker can read:** the key. It runs as the key's identity for as long as the
  key is valid, which is why the account should hold Vertex AI access only and a
  dedicated project is best.
* **Exfiltration:** only through the egress proxy, whose allowlist limits it as for every
  other provider credential.
* **At rest:** encrypted in the primary's database; on a node only on the pod's memory
  volume, for the run's life. In a cluster, anyone with pod `exec` or node access can
  read it while the run lives (K§12: per-run delivery bounds persistence, not exposure).
* **Logs:** the key is never on argv, in a request, a pod spec, a heartbeat or a log;
  worker output is scrubbed of it (the whole file, its `private_key` and
  `private_key_id`).
* **Rotation:** a service-account key does not rotate on use, so unlike Codex's
  `auth.json` there is nothing to carry back from a run.

## What was and was not verified

Verified in the test suite: the credential kind and its encryption, the `arb` command,
the container's mounts, secret and env, the pod's `/boot` delivery and memory-volume
layout (the real `seed` script), the pod spec holding no key, the controller's
`caps.agy`, and placement sending an agy run to an agy node.

Not verified, because no Google Cloud project and no live cluster were available: a real
key signing in through Vertex AI, the exact roles Google requires (the two above are
Google's documented ones for calling Vertex AI with a quota project), and a live pod on a
real cluster. The first live agy run on a cluster node is that check.
