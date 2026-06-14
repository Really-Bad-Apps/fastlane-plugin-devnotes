# fastlane-plugin-devnotes

[![Gem Version](https://img.shields.io/gem/v/fastlane-plugin-devnotes.svg)](https://rubygems.org/gems/fastlane-plugin-devnotes)

Fastlane plugin that fetches an AI-generated release-notes format from the [DevNotes](https://api.devnotes.ai) API during an Android build and writes it into the source tree so it ships as a bundled resource inside the APK. Defaults to the `mobile-html` format (the standard Android "What's New" HTML); pick another via `format_slug:` if your project defines additional formats (X posts, WordPress, Play Store, …) in the DevNotes web UI.

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
    tag: "v0.3.0"
```

Then:

```bash
bundle install
```

> Pin a specific `tag:` for production builds. `branch: "main"` works for testing but is a rolling reference.

> ⚠️ **Upgrading from v0.2.x?** v0.3.0 is the cutover to DevNotes backend v89's lazy format-output endpoint. The plugin no longer reads `result_data.mobile_notes` from the job (it's been removed server-side); instead it fetches the chosen format via a follow-up call. v0.2.x Fastfiles keep working unchanged in the default case (no `format_slug:` arg ⇒ `"mobile-html"`), but they will **stop working against backend v89+** because `result_data.mobile_notes` is gone — bump the plugin pin.

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
    project_slug: "<owner-username>/<project-slug>",   # e.g. "byteforge/podcast-guru-android"
    release_name: options[:version_name]               # optional; defaults to last_git_tag
    # format_slug defaults to "mobile-html" — set explicitly if your
    #   project defines additional formats and you want a different one.
    # output_path defaults to app/src/main/res/raw/rnotes.txt
  )

  gradle(task: "clean assembleRelease")
end
```

The `<owner-username>/<project-slug>` form is the **stable, GitHub-style identifier**. Project display names can change in the DevNotes UI; slugs cannot. If the bare slug is unambiguous across the projects your API key has access to, you can drop the `<owner-username>/` prefix.

Read the bundled file at runtime from your Android app:

```kotlin
val html = resources.openRawResource(R.raw.rnotes)
  .bufferedReader().use { it.readText() }
textView.text = HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_LEGACY)
```

---

## Action: `devnotes_fetch_inline`

Submits a release-notes generation job, polls until it completes, then lazily fetches the chosen format's output and writes the bytes to `output_path`. Hard-fails the lane on any unrecoverable error.

| Option           | Env var                   | Required             | Default                                   | Notes |
| ---------------- | ------------------------- | -------------------- | ----------------------------------------- | ----- |
| `api_url`        | `DEVNOTES_API_URL`        | no                   | `https://api.devnotes.ai`                 | Override for staging or self-hosted DevNotes. |
| `api_key`        | `DEVNOTES_API_KEY`        | **yes**              | —                                         | Bearer token. Marked sensitive — set via env var, never check in. |
| `project_slug`   | `DEVNOTES_PROJECT_SLUG`   | one of these three   | —                                         | **Recommended.** GitHub-style `"<owner>/<slug>"` or bare `"<slug>"` (auto-resolved when unambiguous). |
| `project_id`     | `DEVNOTES_PROJECT_ID`     | one of these three   | —                                         | Numeric DevNotes project id — stable but opaque. |
| `project_name`   | `DEVNOTES_PROJECT_NAME`   | one of these three   | —                                         | **Deprecated.** Project display name — mutable, will break the build on rename. Backend sunsets the `/by-name/` endpoint 2026-09-07. |
| `format_slug`    | `DEVNOTES_FORMAT_SLUG`    | no                   | `"mobile-html"`                           | Which DevNotes format to bundle. The default ships the standard Android "What's New" HTML. Define additional formats (X posts, WordPress, Play Store notes, …) per-project in the DevNotes web UI. |
| `release_name`   | `DEVNOTES_RELEASE_NAME`   | no                   | `last_git_tag`                            | E.g. `"2.3.0-beta1"`. Identifies the release to generate notes for. |
| `from_tag`       | `DEVNOTES_FROM_TAG`       | no                   | auto-detected from production store       | Git tag to diff from. Leave unset to let DevNotes resolve. |
| `output_path`    | `DEVNOTES_OUTPUT_PATH`    | no                   | `app/src/main/res/raw/rnotes.txt`         | Relative paths resolve against the **project root** (parent of `fastlane/`). Absolute paths are honoured as-is. |
| `poll_interval`  | `DEVNOTES_POLL_INTERVAL`  | no                   | `10`                                      | Seconds between job-status polls. Must be > 0. |
| `timeout`        | `DEVNOTES_TIMEOUT`        | no                   | `600`                                     | Total seconds to wait for generation. Must be > 0. |

**Returns:** absolute path of the file that was written.

---

## Behavior

### Flow

1. Resolves the DevNotes project by `project_slug` (one lookup; bare slug or `owner/slug`), `project_id` (still one lookup — v0.3.0 needs the project's `(owner_username, slug)` pair for the format endpoint, regardless of which identifier you passed), or `project_name` (deprecated, one lookup).
2. Submits a generation job.
3. Polls the job status every `poll_interval` seconds, up to `timeout`, on a single keep-alive HTTP connection.
4. On completion, calls `GET /api/projects/<owner>/<slug>/releases/<release_id>/formats/<format_slug>` to lazy-fetch the chosen format's output (cache-hit usually returns in milliseconds).
5. Writes `content` to `output_path` as UTF-8 bytes (creates parent directories as needed).

### Caching

DevNotes caches each format's output by `(format_id, commit_hash, model, prompt_hash)`. A second build of the same tag with the same prompt short-circuits the LLM and returns the cached bytes immediately — there's no cost penalty to running the action on every build. Editing the format's prompt in the UI produces a fresh `prompt_hash` on the next call, which forces a regenerate.

### Retries

Transient 5xx responses and network errors (connection reset, timeout, TLS error) retry up to 6 times with `poll_interval` seconds between attempts. 4xx responses and contract errors fail immediately — they're not going to fix themselves.

### Failure modes

The action calls `UI.user_error!` and aborts the lane on:

| Cause                                    | What you'll see                                     |
| ---------------------------------------- | --------------------------------------------------- |
| Missing or invalid API key (`401`)       | `DevNotes API error: HTTP 401: …`                   |
| Caller not a member of the project (`403`) | `DevNotes API error: HTTP 403: …`                 |
| Project, release, or format not found (`404`) | `DevNotes API error: HTTP 404: Format '<slug>' not found` |
| Bare slug matches >1 project (`409`)     | `DevNotes: Ambiguous slug …` followed by the candidate list as `project_slug: "<owner>/<slug>"` lines |
| Request validation failed (`422`)        | `DevNotes API error: HTTP 422: json.<field>: …`     |
| Prompt template references an unknown variable (`422`) | `DevNotes API error: HTTP 422: Prompt template references unknown variable: …` — fix the format's prompt in the DevNotes UI. |
| Transient LLM failure during format generation (`503`) | Retried up to 6 times; if persistent, `DevNotes API error: Gave up after 6 consecutive …` |
| DevNotes job marked `failed`             | `DevNotes job N failed: <error_message>`            |
| `timeout` elapsed before completion      | `DevNotes API error: Timed out after Ns waiting for job N` |
| Persistent 5xx / network failures        | `DevNotes API error: Gave up after 6 consecutive …` |

### Disambiguation

If your API key has access to projects in more than one DevNotes account that happen to share the same slug, the bare-`<slug>` form is ambiguous. The action will fail loud with the candidate list, formatted as copy-paste-ready lines:

```
DevNotes: Ambiguous slug 'podcast-guru-android' — 2 accessible projects share this slug
Re-run with the explicit owner/slug form:
  project_slug: "alice/podcast-guru-android"
  project_slug: "byteforge/podcast-guru-android"
```

Pick the correct one and switch to the `"<owner>/<slug>"` form in your `Fastfile`. The explicit form never returns 409.

---

## Android `res/raw/` filename rules

Android requires filenames under `res/raw/` (and its qualifier variants like `raw-en/`, `raw-night/`, `raw-v21/`) to match `[a-z0-9_.]+` — lowercase letters, digits, underscore, dot. The action validates this whenever `output_path` targets a `res/raw…/` directory and aborts with a clear error if the name is invalid.

The resource id is the filename minus the extension: `rnotes.txt` → `R.raw.rnotes`.

---

## CI setup

In your CI secret store, set:

```
DEVNOTES_API_KEY         # the bearer token (required)
DEVNOTES_PROJECT_SLUG    # recommended; "<owner>/<slug>" or bare "<slug>"
# DEVNOTES_PROJECT_ID    # alternative; numeric, stable but opaque
# DEVNOTES_PROJECT_NAME  # deprecated; mutable display name
# DEVNOTES_FORMAT_SLUG   # optional; defaults to "mobile-html"
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
    tag: "v0.3.1"   # ← update tag
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
