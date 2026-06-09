# fastlane-plugin-devnotes

[![Gem Version](https://img.shields.io/gem/v/fastlane-plugin-devnotes.svg)](https://rubygems.org/gems/fastlane-plugin-devnotes)

Fastlane plugin that fetches AI-generated mobile release notes from the [DevNotes](https://api.devnotes.ai) API during an Android build and writes them into the source tree so they ship as a bundled resource inside the APK.

Contributed by [@jmazzahacks](https://github.com/jmazzahacks).

---

## Prerequisites

- A DevNotes account with a project configured for your Android app.
- A DevNotes **API key** (Bearer token). Obtain it from your DevNotes admin or your account at [devnotes.ai](https://devnotes.ai).
- The DevNotes project must be linked to the GitHub repository whose commits will be summarised.
- Fastlane 2.200+ and Ruby 2.6+.

---

## Install

Add to your project's `fastlane/Pluginfile`:

```ruby
gem "fastlane-plugin-devnotes",
    git: "https://github.com/Really-Bad-Apps/fastlane-plugin-devnotes.git",
    tag: "v0.1.1"
```

Then:

```bash
bundle install
```

> Pin a specific `tag:` for production builds. `branch: "main"` works for testing but is a rolling reference.

---

## Quick start

Set the API key in your build environment (don't commit it):

```bash
export DEVNOTES_API_KEY="…"
```

In your `Fastfile`, call the action **before** `gradle assembleRelease` so the file is included when Gradle compiles resources:

```ruby
lane :release do |options|
  devnotes_fetch_inline(
    project_name: "<your-devnotes-project-name>",
    release_name: options[:version_name]      # optional; defaults to last_git_tag
    # output_path defaults to app/src/main/res/raw/rnotes.txt
  )

  gradle(task: "clean assembleRelease")
end
```

Read the bundled file at runtime from your Android app:

```kotlin
val html = resources.openRawResource(R.raw.rnotes)
  .bufferedReader().use { it.readText() }
textView.text = HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_LEGACY)
```

---

## Action: `devnotes_fetch_inline`

Submits a release-notes generation job, polls until it completes, and writes the mobile HTML variant to `output_path`. Hard-fails the lane on any unrecoverable error.

| Option           | Env var                   | Required             | Default                                   | Notes |
| ---------------- | ------------------------- | -------------------- | ----------------------------------------- | ----- |
| `api_url`        | `DEVNOTES_API_URL`        | no                   | `https://api.devnotes.ai`                 | Override for staging or self-hosted DevNotes. |
| `api_key`        | `DEVNOTES_API_KEY`        | **yes**              | —                                         | Bearer token. Marked sensitive — set via env var, never check in. |
| `project_name`   | `DEVNOTES_PROJECT_NAME`   | one of these two     | —                                         | DevNotes project name. Mutually exclusive with `project_id`. |
| `project_id`     | `DEVNOTES_PROJECT_ID`     | one of these two     | —                                         | Numeric DevNotes project id. Mutually exclusive with `project_name`. |
| `release_name`   | `DEVNOTES_RELEASE_NAME`   | no                   | `last_git_tag`                            | E.g. `"2.3.0-beta1"`. Identifies the release to generate notes for. |
| `from_tag`       | `DEVNOTES_FROM_TAG`       | no                   | auto-detected from production store       | Git tag to diff from. Leave unset to let DevNotes resolve. |
| `output_path`    | `DEVNOTES_OUTPUT_PATH`    | no                   | `app/src/main/res/raw/rnotes.txt`         | Relative paths resolve against the **project root** (parent of `fastlane/`). Absolute paths are honoured as-is. |
| `poll_interval`  | `DEVNOTES_POLL_INTERVAL`  | no                   | `10`                                      | Seconds between job-status polls. Must be > 0. |
| `timeout`        | `DEVNOTES_TIMEOUT`        | no                   | `600`                                     | Total seconds to wait for generation. Must be > 0. |

**Returns:** absolute path of the file that was written.

---

## Behavior

### Flow

1. Resolves the DevNotes project by `project_name` (one lookup) or `project_id` (no lookup).
2. Submits a generation job.
3. Polls the job status every `poll_interval` seconds, up to `timeout`, on a single keep-alive HTTP connection.
4. On completion, writes the mobile HTML to `output_path` as UTF-8 bytes (creates parent directories as needed).

### Caching

DevNotes caches generated notes by `(project, commit, model)`. A second build of the same tag short-circuits the LLM and returns the cached notes in milliseconds — there's no cost penalty to running the action on every build.

### Retries

Transient 5xx responses and network errors (connection reset, timeout, TLS error) retry up to 6 times with `poll_interval` seconds between attempts. 4xx responses and contract errors fail immediately — they're not going to fix themselves.

### Failure modes

The action calls `UI.user_error!` and aborts the lane on:

| Cause                                    | What you'll see                                     |
| ---------------------------------------- | --------------------------------------------------- |
| Missing or invalid API key (`401`)       | `DevNotes API error: HTTP 401: …`                   |
| Caller not a member of the project (`403`) | `DevNotes API error: HTTP 403: …`                 |
| Project not found (`404`)                | `DevNotes API error: HTTP 404: Project … not found` |
| Request validation failed (`422`)        | `DevNotes API error: HTTP 422: json.<field>: …`     |
| DevNotes job marked `failed`             | `DevNotes job N failed: <error_message>`            |
| `timeout` elapsed before completion      | `DevNotes API error: Timed out after Ns waiting for job N` |
| Persistent 5xx / network failures        | `DevNotes API error: Gave up after 6 consecutive …` |

---

## Android `res/raw/` filename rules

Android requires filenames under `res/raw/` (and its qualifier variants like `raw-en/`, `raw-night/`, `raw-v21/`) to match `[a-z0-9_.]+` — lowercase letters, digits, underscore, dot. The action validates this whenever `output_path` targets a `res/raw…/` directory and aborts with a clear error if the name is invalid.

The resource id is the filename minus the extension: `rnotes.txt` → `R.raw.rnotes`.

---

## CI setup

In your CI secret store, set:

```
DEVNOTES_API_KEY        # the bearer token (required)
DEVNOTES_PROJECT_NAME   # or DEVNOTES_PROJECT_ID
```

With those exported, the Fastfile call can be parameter-free and the action picks values from the environment.

Note: `release_name` defaults to `last_git_tag`. Most CI checkouts are shallow and won't have tags. Fetch them before the action runs:

```bash
git fetch --tags --force --no-recurse-submodules
```

Or pass `release_name:` explicitly from your lane parameters.

---

## Upgrade

Bump the `tag:` in your Pluginfile and run `bundle install`:

```ruby
gem "fastlane-plugin-devnotes",
    git: "https://github.com/Really-Bad-Apps/fastlane-plugin-devnotes.git",
    tag: "v0.1.2"   # ← update tag
```

Releases are tagged in this repo; check the [tags](https://github.com/Really-Bad-Apps/fastlane-plugin-devnotes/tags) page for what's available.

---

## Development

```bash
bundle install
gem build fastlane-plugin-devnotes.gemspec
```

---

## License

Released under the O'Saasy License. See [LICENSE](LICENSE).
