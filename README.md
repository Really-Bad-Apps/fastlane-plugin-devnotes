# fastlane-plugin-devnotes

[![Gem Version](https://img.shields.io/gem/v/fastlane-plugin-devnotes.svg)](https://rubygems.org/gems/fastlane-plugin-devnotes)

Fetch AI-generated mobile release notes from the [DevNotes](https://api.devnotes.ai) API during a Fastlane build and write them into the Android source tree so they ship inside the APK.

Contributed by [@jmazzahacks](https://github.com/jmazzahacks).

## Getting Started

Add to your project's `fastlane/Pluginfile`:

```ruby
gem "fastlane-plugin-devnotes",
    git: "https://github.com/Really-Bad-Apps/fastlane-plugin-devnotes.git",
    tag: "v0.1.0"
```

Or once published to RubyGems:

```ruby
gem "fastlane-plugin-devnotes"
```

## Usage

Set the API key in your build environment:

```bash
export DEVNOTES_API_KEY="sk_..."
```

Call the action from a lane:

```ruby
lane :build_release do |options|
  devnotes_fetch_inline(
    project_name: "Podcast Guru Android",
    release_name: options[:version_name],          # defaults to last_git_tag if omitted
    output_path:  "app/src/main/res/raw/rnotes.txt"
  )

  gradle(task: "clean assembleRelease")
end
```

At runtime the Android app reads the bundled file:

```kotlin
val html = resources.openRawResource(R.raw.rnotes).bufferedReader().use { it.readText() }
textView.text = HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_LEGACY)
```

## Action: `devnotes_fetch_inline`

Submits a release-notes generation job, polls until complete, and writes the mobile HTML variant to `output_path`. Hard-fails the lane on any error (auth, timeout, generation failure).

| Option          | Env var                  | Required | Default                                | Notes |
| --------------- | ------------------------ | -------- | -------------------------------------- | ----- |
| `api_url`       | `DEVNOTES_API_URL`       | no       | `https://api.devnotes.ai`              | Override for staging / local dev. |
| `api_key`       | `DEVNOTES_API_KEY`       | **yes**  | —                                      | Bearer token. Sensitive. |
| `project_name`  | `DEVNOTES_PROJECT_NAME`  | one of   | —                                      | Provide either `project_name` or `project_id`. |
| `project_id`    | `DEVNOTES_PROJECT_ID`    | one of   | —                                      | Provide either `project_name` or `project_id`. |
| `release_name`  | `DEVNOTES_RELEASE_NAME`  | no       | `last_git_tag`                         | E.g. `"2.3.0-beta1"`. |
| `from_tag`      | `DEVNOTES_FROM_TAG`      | no       | auto-detected from production store    | Git tag to compare from. |
| `output_path`   | `DEVNOTES_OUTPUT_PATH`   | no       | `app/src/main/res/raw/rnotes.txt`      | Validated against `[a-z0-9_.]+` when path contains `res/raw/`. |
| `poll_interval` | `DEVNOTES_POLL_INTERVAL` | no       | `10`                                   | Seconds between job-status polls. |
| `timeout`       | `DEVNOTES_TIMEOUT`       | no       | `600`                                  | Total seconds to wait. |

**Returns:** absolute path of the file written.

### Caching

DevNotes caches generated notes by `(project_id, commit_hash, model)`. A second build of the same tag short-circuits the LLM and returns the cached notes in milliseconds — there's no cost penalty to running this action on every build.

### `res/raw/` filename rules

Android requires filenames under `res/raw/` to match `[a-z0-9_.]+`. The action enforces this when `output_path` contains `res/raw/`. The resource id is the filename minus the extension: `rnotes.txt` → `R.raw.rnotes`.

## Development

```bash
bundle install
bundle exec rspec
```

## License

This project is released under the O'Saasy License. See [LICENSE](LICENSE).
