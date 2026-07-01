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
    tag: "v0.8.1"
```

Then:

```bash
bundle install
```

> Pin a specific `tag:` for production builds. `branch: "main"` works for testing but is a rolling reference.

> ✨ **What's new in v0.8.1?** Empty-string key in `qualifier_overrides:` now rescues the bare `values/` (default Android qualifier) dir — declare `qualifier_overrides: { "" => "en-US", ... }` and auto-discovery includes your default-language listing (usually en-US) alongside the qualified ones. Without the declaration, `values/` is still skipped with a warning (backward-compatible). Fixes the "auto-discovery drops the primary Play Store listing" case surfaced during the PodcastGuru integration. See [Recommended production recipe](#recommended-production-recipe).

> ⚠️ **BREAKING in v0.8.0 (2026-07-01):** `devnotes_write_play_changelogs` auto-discovery now scans `<res_path>/values-*/` instead of `<res_path>/raw-*/`. The `values-<qualifier>/` tree is the canonical Android "we ship this language" signal — the resource compiler pulls a locale into the AAB iff a `values-<qualifier>/` dir exists for it, so it's the correct source of truth for "what locales does this app support." Auto-discovery from `raw-*/` (v0.6.x default) was a leftover coupling to `devnotes_fetch_inline`'s output and could lag behind the actual shipped-locales set. **Migration:** if your Fastfile passes `locales: [...]` explicitly, no change needed — the explicit path is unchanged. If your Fastfile relied on auto-discovery, verify your `values-*/` set matches what you actually ship (which it should — that's what Android compiles from). Skipping v0.7 in the tag history: v0.7 conceptually would have been the deprecation-warning intermediate release; skipped because current external consumers all use explicit `locales:` and the values-*/ scan Just Works for them.

> ✨ **What else in v0.8.0:** All the v0.6.1 safety knobs remain — `qualifier_overrides:` (Rosetta table consulted BEFORE the ambiguity guard, rescues pt/zh/es/fa/hy), `strict: true` (silent language-drop → hard-fail). The region-dedup pass stays gone. `values-night/`, `values-mdpi/`, `values-w720dp/`, `values-v21/`, and every other non-locale Android qualifier fall through to `:malformed` and skip cleanly. See [Auto-discovery caveats](#auto-discovery-caveats).

> ✨ **What's new in v0.5.0?** Optional `locale:` action option (env `DEVNOTES_LOCALE`) — pass a BCP 47 tag like `"es-MX"` or `"ru-RU"` to bundle a translated format output. Backwards-compatible: existing Fastfiles work unchanged (no `locale:` ⇒ source English). See [Translations](#translations) below.

> ⚠️ **Upgrading from v0.3.x?** v0.4.0 was the cutover to DevNotes backend v91's slug-canonical project routes (Phase 2 of the UUID PK migration). The `project_id:` option is gone — pass `project_slug:` instead. Fastfiles that already used `project_slug:` (the recommended path since v0.3.0) work unchanged. Fastfiles using `project_id: 1` will **stop working against backend v91+** because the `<int:project_id>` routes were dropped — switch to `project_slug: "owner/slug"`.

> ⚠️ **Upgrading from v0.2.x?** v0.3.0 was the cutover to DevNotes backend v89's lazy format-output endpoint. The plugin no longer reads `result_data.mobile_notes` from the job (it's been removed server-side); instead it fetches the chosen format via a follow-up call. v0.2.x Fastfiles keep working unchanged in the default case (no `format_slug:` arg ⇒ `"mobile-html"`), but they will **stop working against backend v89+** because `result_data.mobile_notes` is gone — bump the plugin pin.

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

### Full Play Store flow (multi-locale)

Combine `devnotes_fetch_inline` (per locale, populates the in-app `res/raw-*/rnotes.txt`) with `devnotes_write_play_changelogs` (writes the per-locale Play Store changelogs into supply's metadata tree), then upload via `supply`:

```ruby
lane :release do |options|
  locales = ["en-US", "ru-RU", "es-MX", "pt-BR", "de-DE"]

  # 1. In-app HTML release notes — one rnotes.txt per Android resource qualifier
  locales.each do |loc|
    qual = loc == "en-US" ? "raw" : "raw-#{loc.sub(/-([A-Z]{2})$/) { "-r#{$1}" }}"
    devnotes_fetch_inline(
      project_slug: "byteforge/podcast-guru-android",
      locale:       loc == "en-US" ? nil : loc,
      output_path:  "app/src/main/res/#{qual}/rnotes.txt",
    )
  end

  # 2. Play Store changelogs — one file per Play Store metadata locale
  devnotes_write_play_changelogs(
    project_slug: "byteforge/podcast-guru-android",
    format_slug:  "play-store-changelog",
    version_code: android_get_version_code(...),
    # locales: auto-discovered from res/raw-*/ above
  )

  # 3. Build + upload
  gradle(task: "clean bundleRelease")
  upload_to_play_store(skip_upload_apk: true)
end
```

The Play Store format must be defined in the DevNotes UI for your project before step 2 — see the [Play Store format setup](#play-store-format-setup) section below.

---

## Action: `devnotes_fetch_inline`

Submits a release-notes generation job, polls until it completes, then lazily fetches the chosen format's output and writes the bytes to `output_path`. Hard-fails the lane on any unrecoverable error.

| Option           | Env var                   | Required             | Default                                   | Notes |
| ---------------- | ------------------------- | -------------------- | ----------------------------------------- | ----- |
| `api_url`        | `DEVNOTES_API_URL`        | no                   | `https://api.devnotes.ai`                 | Override for staging or self-hosted DevNotes. |
| `api_key`        | `DEVNOTES_API_KEY`        | **yes**              | —                                         | Bearer token. Marked sensitive — set via env var, never check in. |
| `project_slug`   | `DEVNOTES_PROJECT_SLUG`   | one of these two     | —                                         | **Recommended.** GitHub-style `"<owner>/<slug>"` or bare `"<slug>"` (auto-resolved when unambiguous). |
| `project_name`   | `DEVNOTES_PROJECT_NAME`   | one of these two     | —                                         | **Deprecated.** Project display name — mutable, will break the build on rename. Backend sunsets the `/by-name/` endpoint 2026-09-07. |
| `format_slug`    | `DEVNOTES_FORMAT_SLUG`    | no                   | `"mobile-html"`                           | Which DevNotes format to bundle. The default ships the standard Android "What's New" HTML. Define additional formats (X posts, WordPress, Play Store notes, …) per-project in the DevNotes web UI. |
| `locale`         | `DEVNOTES_LOCALE`         | no                   | —                                         | Optional BCP 47 tag (e.g. `"es-MX"`, `"ru-RU"`) requesting a translated format output. Omitted or `"en-*"` returns source English. See [Translations](#translations) for multi-locale build patterns and the `max_char_length` failure mode. |
| `release_name`   | `DEVNOTES_RELEASE_NAME`   | no                   | `last_git_tag`                            | E.g. `"2.3.0-beta1"`. Identifies the release to generate notes for. |
| `from_tag`       | `DEVNOTES_FROM_TAG`       | no                   | auto-detected from production store       | Git tag to diff from. Leave unset to let DevNotes resolve. |
| `output_path`    | `DEVNOTES_OUTPUT_PATH`    | no                   | `app/src/main/res/raw/rnotes.txt`         | Relative paths resolve against the **project root** (parent of `fastlane/`). Absolute paths are honoured as-is. |
| `poll_interval`  | `DEVNOTES_POLL_INTERVAL`  | no                   | `10`                                      | Seconds between job-status polls. Must be > 0. |
| `timeout`        | `DEVNOTES_TIMEOUT`        | no                   | `600`                                     | Total seconds to wait for generation. Must be > 0. |

**Returns:** absolute path of the file that was written.

---

## Action: `devnotes_write_play_changelogs`

Fetches a per-locale DevNotes format (e.g. `play-store-changelog` with `max_char_length=480`) for each locale in scope and writes the bytes to `fastlane/metadata/android/<play_store_locale>/changelogs/<version_code>.txt` — the path `supply` (a.k.a. `upload_to_play_store`) expects. Hard-fails the lane on the first per-locale error so half-localized changelogs never reach Play Console.

| Option              | Env var                            | Required | Default                             | Notes |
| ------------------- | ---------------------------------- | -------- | ----------------------------------- | ----- |
| `api_url`           | `DEVNOTES_API_URL`                 | no       | `https://api.devnotes.ai`           | Override for staging / self-hosted. |
| `api_key`           | `DEVNOTES_API_KEY`                 | **yes**  | —                                   | Bearer token. Sensitive — set via env. |
| `project_slug`      | `DEVNOTES_PROJECT_SLUG`            | one of these two | —                          | Recommended: `"<owner>/<slug>"` or bare slug. |
| `project_name`      | `DEVNOTES_PROJECT_NAME`            | one of these two | —                          | Deprecated; same sunset as `devnotes_fetch_inline`. |
| `release_name`      | `DEVNOTES_RELEASE_NAME`            | no       | `last_git_tag`                      | E.g. `"2.3.0-beta1"`. |
| `from_tag`          | `DEVNOTES_FROM_TAG`                | no       | auto-detected from prod store       | Git tag to diff from. |
| `format_slug`       | `DEVNOTES_PLAY_FORMAT_SLUG`        | no       | `"play-store-changelog"`            | The DevNotes format to fetch per locale. Define it in the DevNotes UI with `max_char_length=480` and a plain-text + emoji prompt — see [Play Store format setup](#play-store-format-setup). |
| `version_code`      | `DEVNOTES_PLAY_VERSION_CODE`       | **yes**  | —                                   | The Android `versionCode` the changelog attaches to. Integer or String of digits. Must match the build supply uploads or the changelog attaches to the wrong build. |
| `locales`           | `DEVNOTES_PLAY_LOCALES`            | no       | auto-discover from `<res_path>/values-*/` | Explicit BCP 47 list (e.g. `["en-US", "ru-RU"]`). When set, `res_path` is NOT inspected. Use this when you want to ship a subset of your app's locales to Play (e.g. app supports 15 languages but Play Console only has listings for 5). Otherwise the auto-discovery default (values-*/) is the right choice — that's what the AAB itself compiles from. |
| `res_path`          | `DEVNOTES_PLAY_RES_PATH`           | no       | `app/src/main/res`                  | Root of the Android resource directory (containing the `values-*/` dirs) to scan when auto-discovering locales. Relative paths resolve from the project root. **If your module puts `res/` at the module root (legacy / flat Gradle layout), set this to `"res"` or auto-discovery finds nothing.** |
| `metadata_path`     | `DEVNOTES_PLAY_METADATA_PATH`      | no       | `fastlane/metadata/android`         | Root of the supply metadata tree. Relative paths resolve from the project root. |
| `qualifier_overrides` | `DEVNOTES_PLAY_QUALIFIER_OVERRIDES` | no    | `{}`                                | Android resource qualifier → BCP 47 escape hatch, e.g. `{ "" => "en-US", "pt" => "pt-PT", "es" => "es-419", "fa" => "fa" }`. Consulted BEFORE any built-in rule inside `qualifier_to_bcp47`, so this rescues (a) the bare `values/` (default qualifier) dir via the **empty-string key `""`** — otherwise auto-discovery skips it and your default-language Play Store listing drops from the release; (b) ambiguous bare-languages (pt/zh/es — otherwise hard-fail); (c) unmapped bare-languages (fa, hy, … — otherwise silently skip). Auto-discovery only; ignored when `locales:` is set. |
| `strict`            | `DEVNOTES_PLAY_STRICT`             | no       | `false`                             | When `true`, an unmapped bare-language qualifier hard-fails the build instead of skipping with a warning. Genuine non-locale qualifiers (`values-night`, `values-v21`, `values-mdpi`, `values-w720dp`) still skip regardless. **Recommended for production**: a language you ship should never vanish from a release just because someone added a new `values-<lang>/` dir the plugin doesn't know about. |
| `locale_overrides`  | `DEVNOTES_PLAY_LOCALE_OVERRIDES`   | no       | `{}`                                | BCP 47 → Play Store metadata code rewrites (e.g. `{ "es-419" => "es-MX" }` to override the default Spanish collapse). Applied AFTER `qualifier_to_bcp47`. **This CANNOT rescue an ambiguous bare-language** (`values-pt`, `values-zh`, `values-es`) — that path raises inside `qualifier_to_bcp47` before `locale_overrides` is consulted. Use `qualifier_overrides:` for that case. |
| `poll_interval`     | `DEVNOTES_POLL_INTERVAL`           | no       | `10`                                | Seconds between job-status polls. |
| `timeout`           | `DEVNOTES_TIMEOUT`                 | no       | `600`                               | Total seconds to wait for generation. |

**Returns:** Hash — `{ locales: [...], paths: [...], skipped: [...] }`. Also stored in lane context as `SharedValues::DEVNOTES_PLAY_CHANGELOG_PATHS`.

**Order:** runs BEFORE `upload_to_play_store(skip_upload_apk: true)`. supply reads `fastlane/metadata/android/<locale>/changelogs/<vc>.txt` and uploads alongside the release track update.

### Content vs. selection

The `res/` tree is consulted **only** to decide WHICH locales to request from DevNotes. The plugin never reads the CONTENT of any file under `values-<lang>/` — the changelog text for each locale is generated fresh by the DevNotes backend (per-locale translation, `max_char_length` retry, etc.). So `res/values-<lang>/` presence answers "does this app ship in language X?" but not "what does the release note say?"

That distinction matters because the Android qualifier → Play Store locale mapping is a product decision the plugin fundamentally cannot infer — the two code systems are misaligned by design (`values-zh-rCN` vs `zh-CN`, `values-b+es+419` vs `es-419`, legacy `iw`/`in` vs standard `he`/`id`, distinct listings for `es-ES` vs `es-419` that don't share a source dir). Any multi-locale app hitting the ambiguous or divergent cases (pt/zh/es, script tags, custom regional listings) needs `qualifier_overrides:` to declare the intended mapping.

### Auto-discovery caveats

Auto-discovery scans `<res_path>/values-*/` for directories and maps each Android resource qualifier to a BCP 47 code. Three ways it can go silently wrong — `qualifier_overrides:` + `strict: true` neutralize all three:

| Failure mode | Default behavior | Fix |
| --- | --- | --- |
| **Ambiguous bare-language** — `values-pt` / `values-zh` / `values-es`. Legit locale attempts but incomplete (BR vs PT, CN vs TW vs HK, ES vs 419 vs MX). | 💥 hard-fail with a clear error | Declare the intended mapping in `qualifier_overrides: { "pt" => "pt-PT", ... }` — that check runs BEFORE the ambiguity guard. |
| **Unmapped bare-language** — `values-fa` (Farsi), `values-hy` (Armenian), any language not in the built-in `BARE_LANGUAGE_DEFAULTS` table. | ⚠️ **SILENTLY SKIPPED** with a `UI.important` warning. A locale you ship simply vanishes from the release. **This is the failure mode most likely to escape review** — set `strict: true` for production. | `strict: true` turns this into a hard-fail; OR declare it in `qualifier_overrides` and it maps through normally. |
| **`values/` bare (default qualifier)** — Android's "no qualifier" bucket. Represents your app's default language (usually en-US, but the plugin can't safely guess). | ⚠️ silently skipped with warning UNLESS `qualifier_overrides: { "" => "en-US" }` is declared. | Declare the mapping via `qualifier_overrides[""]` (v0.8.1+) to include the default-language listing in auto-discovery. Or add explicitly to `locales:` if not using auto-discovery. |
| **Non-locale Android qualifier** — `values-night`, `values-v21`, `values-w720dp`, `values-mdpi`, `values-port`, `values-mcc310`, etc. These are UI mode, API version, screen size, density, orientation, MCC modifiers, not locales. Every real Android project has some of these. | ✅ skipped with warning (correct behavior) | No action needed. `strict:` does NOT turn these into failures — they're legitimately not locales. |

Additionally:

- **`values-pt` and `values-pt-rBR` both present:** both write. Some apps use the bare form as a distinct Play listing (e.g. `values-es` → es-419 Latin America vs `values-es-rES` → es-ES Spain).
- **Legacy ISO 639 aliases:** Android historically uses `iw`/`in`/`ji`; the plugin translates to `he`/`id`/`yi` at the qualifier layer.
- **`locale_overrides:` does NOT rescue ambiguous cases.** It's applied AFTER `qualifier_to_bcp47`, so a `values-pt` hard-fail is already raised before `locale_overrides` runs. Use `qualifier_overrides:` for that path.

### Recommended production recipe

Set `qualifier_overrides:` (Rosetta table for divergent cases) plus `strict: true` (fail-loud on unmapped new locales) and let auto-discovery do the enumeration — the plugin scans `values-*/` (the canonical shipped-languages signal) natively.

```ruby
lane :deploy_internal do |options|
  # ... your existing gradle / signing / assemble_release steps ...

  devnotes_write_play_changelogs(
    project_slug:  "byteforge/podcast-guru-android",
    format_slug:   "play-store-changelog",
    version_code:  android_get_version_code(gradle_file: "app/build.gradle"),

    # Android qualifier → BCP 47 (or Play Store code — the plugin's
    # allowlist accepts either form). Only entries for cases that
    # AREN'T identity mappings: identity cases (`de` → `de-DE`,
    # `fr` → `fr-FR`, etc.) are handled by the plugin's built-in
    # BARE_LANGUAGE_DEFAULTS. What you MUST declare here:
    #   - Ambiguous bares (pt, zh, es) — otherwise 💥 hard-fail
    #   - Unmapped languages (fa, hy, …) — otherwise ⚠️ silent skip
    #     (`strict: true` upgrades those to hard-fail, but you still
    #     need to declare the mapping to actually ship the locale)
    #   - Divergent regional dialects (es-rES vs es-r419, pt-rBR vs pt-rPT)
    qualifier_overrides: {
      ""       => "en-US",     # bare `values/` — your app's default language.
                               # Without this line auto-discovery SKIPS the
                               # default-language listing and you ship every
                               # non-default locale but silently omit en-US.
      "pt"     => "pt-PT",     # bare = European (or "pt-BR" — your call)
      "pt-rBR" => "pt-BR",
      "es"     => "es-419",    # bare = Latin America
      "es-rES" => "es-ES",     # region-qualified = Spain (distinct Play listing)
      "zh-rCN" => "zh-CN",
      "zh-rTW" => "zh-TW",
      "fa"     => "fa",        # unmapped in plugin defaults — declare here
    },

    # Fail the build if a new values-<lang>/ dir is added without a
    # matching qualifier_overrides entry or a built-in default. Trades
    # a warning for a hard-fail: a language you ship never silently
    # vanishes from a release just because someone added a values dir.
    strict: true,

    # If your module has `res/` at its root (legacy / flat Gradle
    # layout) rather than `app/src/main/res`, uncomment:
    # res_path: "res",
  )

  upload_to_play_store(
    skip_upload_apk: true,
    skip_upload_aab: true,   # if the AAB was uploaded via a prior action
    # No --skip-metadata / --skip-changelogs: supply picks up
    # fastlane/metadata/android/<locale>/changelogs/<vc>.txt automatically.
  )
end
```

**Alternative — explicit `locales:` list.** Use this when you want to ship a subset of your app's locales to Play (e.g. app supports 15 languages but Play Console only has listings for 5), or when your auto-discovered set is genuinely wrong for some reason. `res_path` is never inspected in this mode:

```ruby
devnotes_write_play_changelogs(
  project_slug: "byteforge/podcast-guru-android",
  format_slug:  "play-store-changelog",
  version_code: android_get_version_code(gradle_file: "app/build.gradle"),
  locales:      ["en-US", "ru-RU", "es-419", "es-ES", "pt-PT", "pt-BR", "de-DE"],
)
```

### Locale discovery (reference)

Two modes — explicit `locales:` wins outright over auto-discovery:

- **Explicit** (`locales: [...]`): list verbatim. Each entry maps through the built-in BCP 47 → Play Store quirks (see [Play Store locale conventions](#play-store-locale-conventions)) and then through `locale_overrides:`. `res_path` is never inspected.
- **Auto-discovery** (default when `locales:` is unset): scans `<res_path>/values-*/` for directories. Rule order for each qualifier:
  1. `qualifier_overrides:[qualifier]` if present → use verbatim. The empty-string key `""` maps the bare `values/` dir (v0.8.1+).
  2. `b+<lang>[+<script>[+<region>]]` (newer form) → BCP 47 identity join.
  3. `<lang>-r<REGION>` (region-qualified) → `<lang>-<REGION>` (legacy ISO alias translated: iw→he, in→id, ji→yi).
  4. Bare `<lang>` in `BARE_LANGUAGE_DEFAULTS` (`en`, `ru`, `ko`, `ja`, `de`, `fr`, `it`, `nl`, `pl`, `tr`, `th`, `vi`, `hi`, `ar`, `he`, `id`) → mapped default.
  5. Bare `<lang>` in `AMBIGUOUS_BARE_LANGUAGES` (`pt`, `zh`, `es`) → hard-fail unless step 1 rescued it.
  6. Anything else → skip with warning (or hard-fail if `strict: true`).

Bare `values/` (default qualifier) is skipped with a warning regardless — never inferred as `en-US` because that's wrong for apps whose default language isn't English.

### Play Store format setup

Define a format in the DevNotes UI for the project with:

- **Slug**: `play-store-changelog` (or whatever you pass to `format_slug:`)
- **MIME type**: `text/plain`
- **`max_char_length`**: `480` (Google Play's hard 500-char limit minus translation expansion buffer)
- **Prompt**: plain-text + emoji-friendly, references `{max_chars}` in the user template. The DevNotes backend handles the per-locale translation iteration to fit `max_char_length` (3 attempts; 422 on overshoot).

System + user prompts can mirror the legacy `generate_play_store_release_notes.py` script: convert HTML, target 3-5 bullets with leading emojis, present tense, avoid idioms (since the translator runs downstream).

### Play Store locale conventions

The plugin maps BCP 47 → Play Store metadata locale with these built-in quirks:

| BCP 47 input                        | Play Store output |
| ----------------------------------- | ----------------- |
| `en` (bare)                         | `en-US`           |
| `es-MX`, `es-AR`, `es-CO`, `es-CL`, `es-PE` | `es-419`     |
| `zh-Hans`                           | `zh-CN`           |
| `zh-Hant`                           | `zh-TW`           |
| Anything else                       | passed through    |

Use `locale_overrides:` to undo or extend these. E.g. if your Play Console has a dedicated `es-MX` listing (rather than the collapsed `es-419`), pass `locale_overrides: { "es-419" => "es-MX" }` — the override applies AFTER the quirks pass.

If the final code isn't in the plugin's known-Play-supported allowlist, the action **warns but proceeds** — Google occasionally adds locales before the plugin updates its list.

### Failure modes

| Cause                                              | Severity | What you'll see |
| -------------------------------------------------- | -------- | --------------- |
| Bad `version_code` (non-digit)                     | 💥 hard-fail | `version_code must be a positive integer (digits only); got "..."` |
| Ambiguous bare-language qualifier (`values-pt`, `values-zh`, `values-es`) — no `qualifier_overrides:` entry | 💥 hard-fail | `ambiguous bare-language qualifier 'values-pt' (Brazilian (pt-BR) vs European (pt-PT))…` — declare the mapping in `qualifier_overrides:` or switch to explicit `locales:`. |
| **Unmapped bare-language qualifier** (`values-fa`, `values-hy`, …) — no `qualifier_overrides:` entry and `strict:` off | ⚠️ **SILENT SKIP** — locale vanishes | `skipping 'values-fa' — …` — the locale is dropped, no changelog written. Fix with `qualifier_overrides: { "fa" => "fa" }` OR `strict: true` (which turns this into a hard-fail). |
| Unmapped bare-language qualifier with `strict: true` | 💥 hard-fail | `DevNotes: found 'values-fa' but no BCP 47 mapping for it, and strict: true is set…` |
| Non-locale Android qualifier (`values-night`, `values-v21`, `values-w720dp`, `values-mdpi`, `values-mcc310`, …) | ⚠️ warning + skip | `skipping 'values-night' — …`; auto-discovery continues. Never hard-fails, even under `strict:` — these aren't locales. |
| Bare `values/` (default qualifier) discovered, no `qualifier_overrides[""]` set | ⚠️ warning + skip | `found '<res_path>/values/' (default Android qualifier) — skipping. Declare its mapping via qualifier_overrides: { "" => "en-US" } … or add the desired locale to locales:.` — v0.8.1+ lets you include it in auto-discovery. |
| Per-locale translator can't fit `max_char_length`  | 💥 hard-fail on first offending locale | `DevNotes: format 'play-store-changelog' translation to ru-RU could not fit max_char_length=480 (best attempt was 502 chars after 3 tries)…` |
| Project / release / format / locale not found      | 💥 hard-fail | `DevNotes API error: HTTP 404: …` |
| Auth (`401`) or membership (`403`)                 | 💥 hard-fail | `DevNotes API error: HTTP 401/403: …` |
| Ambiguous bare project slug (`409`)                | 💥 hard-fail | `DevNotes: Ambiguous slug …` (same shape as `devnotes_fetch_inline`) |
| Transient 5xx / network                            | retry up to 6× | Persistent failure aborts with `Gave up after 6 consecutive…` |
| `timeout` elapsed                                  | 💥 hard-fail | `DevNotes API error: Timed out after Ns waiting for job N` |

The **⚠️ silent-skip rows are the ones most likely to escape review** and ship a half-localized release. If your app supports pt/zh/es or any non-Latin-script locale, either use explicit `locales:` (the recommended production recipe) or set `strict: true` with a `qualifier_overrides:` map, so a "we forgot to map this new locale" bug can't reach the store.

### Caveats

- **Two job submissions per lane.** Running both `devnotes_fetch_inline` (per locale) and `devnotes_write_play_changelogs` in the same lane submits two separate generation jobs to the DevNotes API. The backend's `(format_id, commit_hash, model, prompt_hash)` cache short-circuits the LLM, but each job still costs one round-trip (typically under a second on a cache hit). A future v0.7 candidate — a `devnotes_resolve_release` action that exposes the resolved `release_id` via lane context — would let both fetch actions share a single submission. Not in v0.6.
- **`version_code` must match the build supply uploads.** The action writes the changelog file under `changelogs/<version_code>.txt`. If `supply` uploads a different `versionCode`, the changelog attaches to the wrong build. Read `version_code` from the same source supply uses (typically `android_get_version_code` against the AAB).
- **First per-locale error aborts the run.** Files for already-fetched locales remain on disk — the next CI run rewrites them. No partial-success reporting.

---

## Behavior

### Flow

1. Resolves the DevNotes project by `project_slug` (one lookup; bare slug or `owner/slug`) or `project_name` (deprecated, one lookup).
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
| Malformed `locale` (`400`)               | `DevNotes API error: HTTP 400: Invalid locale: expected BCP 47 tag like 'es-MX', got 'es'` — locale must be language+region (e.g. `"es-MX"`, not bare `"es"`). |
| Translator can't fit `max_char_length` (`422`) | `DevNotes: format '<slug>' translation to <locale> could not fit max_char_length=N …` — see [Translations](#translations) for the full message. |
| Transient LLM failure during format generation (`503`) | Retried up to 6 times; if persistent, `DevNotes API error: Gave up after 6 consecutive …` |
| DevNotes job marked `failed`             | `DevNotes job N failed: <error_message>`            |
| `timeout` elapsed before completion      | `DevNotes API error: Timed out after Ns waiting for job N` |
| Persistent 5xx / network failures        | `DevNotes API error: Gave up after 6 consecutive …` |

### Translations

Pass `locale:` (BCP 47, e.g. `"es-MX"` or `"ru-RU"`) to bundle a translated format output. Omitted or any `"en-*"` value returns source English with no extra backend work.

```ruby
devnotes_fetch_inline(
  project_slug: "byteforge/podcast-guru-android",
  format_slug:  "mobile-html",
  locale:       "ru-RU",
  output_path:  "app/src/main/res/raw-ru/rnotes.txt",   # see "Multi-locale builds" below
)
```

When the backend translates, the action's success line includes the locale and attempts count:

```
DevNotes: wrote 1234 bytes (text/html, translated to ru-RU in 2 attempts) to /…/raw-ru/rnotes.txt
```

#### Multi-locale builds

The plugin does **not** auto-embed the locale into `output_path` — Android apps read fixed resource paths, so changing the filename per locale would break the consumer side. Instead, invoke the action once per locale with matching Android resource qualifier directories:

```ruby
[
  { locale: nil,     path: "app/src/main/res/raw/rnotes.txt"     },  # default (en)
  { locale: "ru-RU", path: "app/src/main/res/raw-ru/rnotes.txt"  },
  { locale: "es-MX", path: "app/src/main/res/raw-es/rnotes.txt"  },
].each do |c|
  devnotes_fetch_inline(
    project_slug: "byteforge/podcast-guru-android",
    format_slug:  "mobile-html",
    locale:       c[:locale],
    output_path:  c[:path],
  )
end
```

At runtime Android picks the right `rnotes` resource for the device locale automatically.

#### `max_char_length` and `TranslationFitError`

Formats can carry a `max_char_length` (e.g. 80 for a Play Store short description). When set, the translator iterates up to 3 attempts to fit. If no attempt fits — Cyrillic and German routinely expand 30–50% vs English, so this is a real failure mode for tight limits — the action fails loud with:

```
DevNotes: format 'play-store-short' translation to ru-RU could not fit
max_char_length=80 (best attempt was 94 chars after 3 tries). Either
raise max_char_length on the format in the DevNotes UI, or pick a less
verbose source content for this release.
```

That's enough signal to decide whether the constraint can be widened or whether the English source needs a tighter rewrite.

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
# DEVNOTES_PROJECT_NAME  # deprecated; mutable display name
# DEVNOTES_FORMAT_SLUG   # optional; defaults to "mobile-html"
# DEVNOTES_LOCALE        # optional; BCP 47 tag for translated output
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
    tag: "v0.8.1"   # ← update tag
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
