require "fastlane/action"
require "fileutils"
require_relative "../helper/devnotes_helper"
require_relative "../helper/devnotes_action_mixin"
require_relative "../helper/devnotes_locale_map"

module Fastlane
  module Actions
    module SharedValues
      DEVNOTES_PLAY_CHANGELOG_PATHS = :DEVNOTES_PLAY_CHANGELOG_PATHS
    end

    # For each locale in scope, fetches a per-locale format output
    # (e.g. "play-store-changelog" with max_char_length=480 set in the
    # DevNotes UI) and writes the bytes to supply's expected metadata
    # path: fastlane/metadata/android/<play_store_locale>/changelogs/<vc>.txt.
    # Operator then chains upload_to_play_store(skip_upload_apk: true)
    # to push the changelogs to Play Console.
    class DevnotesWritePlayChangelogsAction < Action
      DEFAULT_API_URL = "https://api.devnotes.ai".freeze
      DEFAULT_FORMAT_SLUG = "play-store-changelog".freeze
      DEFAULT_RES_PATH = "app/src/main/res".freeze
      DEFAULT_METADATA_PATH = "fastlane/metadata/android".freeze
      VERSION_CODE_PATTERN = /\A\d+\z/.freeze

      def self.run(params)
        Helper::DevnotesActionMixin.require_project_identifier(params)

        version_code = params[:version_code].to_s.strip
        unless version_code.match?(VERSION_CODE_PATTERN)
          UI.user_error!(
            "DevNotes: version_code must be a positive integer (digits only); " \
            "got #{params[:version_code].inspect}"
          )
        end

        format_slug = params[:format_slug].to_s.strip
        UI.user_error!("format_slug must not be empty") if format_slug.empty?

        release_name = Helper::DevnotesActionMixin.resolve_release_name(params)
        project_root = Helper::DevnotesActionMixin.project_root
        metadata_path = File.expand_path(params[:metadata_path], project_root)
        overrides = params[:locale_overrides] || {}

        client = Helper::DevnotesHelper.new(
          api_url: params[:api_url],
          api_key: params[:api_key],
          poll_interval: params[:poll_interval],
          timeout: params[:timeout]
        )

        project = Helper::DevnotesActionMixin.resolve_project(client, params)
        project_id = project["id"]
        owner_username = project["created_by_username"]
        project_slug_value = project["slug"]
        if owner_username.nil? || project_slug_value.nil?
          UI.user_error!(
            "DevNotes project #{project_id} has no (created_by_username, slug) pair " \
            "— ask your DevNotes admin to backfill it before re-running this lane."
          )
        end
        UI.message(
          "DevNotes: project=#{owner_username}/#{project_slug_value} (id=#{project_id}) " \
          "release_name=#{release_name} format_slug=#{format_slug} version_code=#{version_code}"
        )

        job = Helper::DevnotesActionMixin.submit_and_wait(
          client, owner_username, project_slug_value, release_name, params[:from_tag]
        )
        release_id = (job["result_data"] || {})["release_id"]
        unless release_id.is_a?(Integer) && release_id.positive?
          UI.user_error!(
            "Job #{job['id']} completed but result_data.release_id is missing or invalid " \
            "(got #{release_id.inspect}). This usually means the DevNotes backend is older " \
            "than v89 (the formats redesign); upgrade the backend and retry."
          )
        end

        # Build the (bcp47, play_store_locale) pair list. Two discovery
        # modes: explicit `locales:` arg wins outright; otherwise scan
        # `<res_path>/raw*` and map qualifiers to BCP 47.
        skipped = []
        qualifier_overrides = params[:qualifier_overrides] || {}
        strict = params[:strict] == true
        pairs = if params[:locales].is_a?(Array) && !params[:locales].empty?
          build_pairs_from_explicit(params[:locales], overrides)
        else
          build_pairs_from_res_path(
            File.expand_path(params[:res_path], project_root),
            overrides,
            qualifier_overrides,
            strict,
            skipped
          )
        end

        if pairs.empty?
          UI.important(
            "DevNotes: no locales to write — pass `locales: [...]` explicitly " \
            "or verify res/values-*/ dirs exist for your shipped locales."
          )
          return finalize({}, skipped)
        end

        paths_written = []
        locales_written = []
        pairs.each do |(bcp47, play_store_locale)|
          UI.message("DevNotes: fetching format '#{format_slug}' for #{bcp47} (Play Store: #{play_store_locale})...")
          output = client.get_format_output(
            owner_username: owner_username,
            project_slug: project_slug_value,
            release_id: release_id,
            format_slug: format_slug,
            locale: bcp47
          )
          content = output["content"]
          unless content.is_a?(String) && !content.empty?
            UI.user_error!(
              "Format '#{format_slug}' returned empty content for locale #{bcp47} " \
              "(got #{content.class}). Check the format's prompt in the DevNotes UI."
            )
          end

          dest = File.join(metadata_path, play_store_locale, "changelogs", "#{version_code}.txt")
          write_utf8(dest, content)
          paths_written << dest
          locales_written << play_store_locale

          if output["translated"]
            UI.success(
              "DevNotes: wrote #{content.bytesize} bytes (translated to " \
              "#{output['locale']} in #{output['translation_attempts']} attempts) " \
              "to #{dest}"
            )
          else
            UI.success("DevNotes: wrote #{content.bytesize} bytes to #{dest}")
          end
        end

        finalize(
          { locales: locales_written, paths: paths_written },
          skipped
        )
      rescue Helper::DevnotesHelper::TranslationFitError => e
        UI.user_error!(
          "DevNotes: format '#{format_slug}' translation to #{e.locale} could not fit " \
          "max_char_length=#{e.max_char_length} (best attempt was #{e.best_length} chars " \
          "after #{e.attempts} tries). Either raise max_char_length on the format " \
          "in the DevNotes UI, or pick a less verbose source content for this release."
        )
      rescue Helper::DevnotesHelper::AmbiguousSlugError => e
        lines = ["DevNotes: #{e.message}", "Re-run with the explicit owner/slug form:"]
        e.candidates.each do |c|
          lines << "  project_slug: \"#{c['owner_username']}/#{c['slug']}\""
        end
        UI.user_error!(lines.join("\n"))
      rescue Helper::DevnotesHelper::ApiError => e
        UI.user_error!("DevNotes API error: #{e.message}")
      end

      # --- locale-set builders ---------------------------------------------

      # Operator-provided locales: array. Map each through bcp47_to_play_store
      # using their overrides. The res path isn't consulted.
      def self.build_pairs_from_explicit(locales, overrides)
        locales.map do |loc|
          bcp47 = loc.to_s.strip
          UI.user_error!("DevNotes: empty entry in locales: array") if bcp47.empty?
          play_store = Helper::DevnotesLocaleMap.bcp47_to_play_store(bcp47, overrides: overrides)
          [bcp47, play_store]
        end
      end

      # Auto-discovery: walk <res_path>/values-* directories — the
      # canonical Android "we ship this language" signal (the resource
      # compiler pulls a locale into the AAB iff a values-<qualifier>/
      # dir exists for it). Map each qualifier to BCP 47 (honoring
      # `qualifier_overrides` first), then to a Play Store code. Skip
      # bare `values/` (default qualifier) with a one-line UI.important
      # rather than guessing en-US — that guess silently writes the
      # wrong file when the app's default language isn't English.
      #
      # Behavior:
      # - `qualifier_overrides` is checked FIRST inside qualifier_to_bcp47,
      #   so the ambiguous (pt/zh/es) hard-fail and the :unknown
      #   silent-skip are both configurable.
      # - `strict: true` turns :unknown from silent-skip into hard-fail
      #   so a supported language never vanishes from a release.
      #   :malformed (non-locale qualifiers like values-night / values-v21 /
      #   values-w720dp / values-mdpi) still skips because those are
      #   genuinely not-locales.
      # - Both `values-<lang>` and `values-<lang>-r<REGION>` write when
      #   both exist — the previous silent region-dedup pass is gone
      #   (was wrong for apps using the bare form as a distinct listing,
      #   e.g. values-es = es-419 vs values-es-rES = es-ES).
      def self.build_pairs_from_res_path(res_path, overrides, qualifier_overrides, strict, skipped)
        unless File.directory?(res_path)
          UI.important(
            "DevNotes: res_path '#{res_path}' is not a directory — nothing to auto-discover. " \
            "Pass `locales: [...]` explicitly or set res_path to your AGP source tree " \
            "(default: app/src/main/res; module-root layouts should pass res_path: 'res')."
          )
          return []
        end

        # Gather every values-* dir; record bare `values/` as skipped.
        qualifiers = []
        Dir.children(res_path).each do |entry|
          full = File.join(res_path, entry)
          next unless File.directory?(full)
          if entry == "values"
            UI.important(
              "DevNotes: found '#{res_path}/values/' (default Android qualifier) — skipping. " \
              "Add the desired locale (e.g. 'en-US') to `locales: [...]` if you want it included."
            )
            skipped << { qualifier: "values", reason: "default qualifier — add to locales: explicitly" }
            next
          end
          if entry.start_with?("values-")
            qualifiers << entry.sub(/\Avalues-/, "")
          end
        end

        # Map each qualifier individually. Non-locale Android qualifiers
        # (values-night, values-v21, values-w720dp, values-mdpi, values-port,
        # …) produce :unknown or :malformed UnmappableQualifierError.
        # :malformed always skips (they're not locales). :unknown skips
        # by default but HARD-FAILS when strict: true (safer prod
        # posture — a supported language never vanishes from a release).
        # AMBIGUOUS bare-languages always hard-fail unless the operator
        # declared a mapping in qualifier_overrides (which
        # qualifier_to_bcp47 checks first).
        pairs = []
        qualifiers.sort.each do |q|
          begin
            bcp47 = Helper::DevnotesLocaleMap.qualifier_to_bcp47(q, overrides: qualifier_overrides)
            play_store = Helper::DevnotesLocaleMap.bcp47_to_play_store(bcp47, overrides: overrides)
            pairs << [bcp47, play_store]
          rescue Helper::DevnotesLocaleMap::UnmappableQualifierError => e
            case e.reason
            when :ambiguous
              UI.user_error!(
                "DevNotes: #{e.message} (Or declare a mapping in " \
                "`qualifier_overrides: { \"#{q}\" => \"<bcp47>\" }` — that check runs BEFORE the ambiguity guard.)"
              )
            when :unknown
              if strict
                UI.user_error!(
                  "DevNotes: found 'values-#{q}' but no BCP 47 mapping for it, and `strict: true` " \
                  "is set. Either add to `qualifier_overrides: { \"#{q}\" => \"<bcp47>\" }`, " \
                  "list it explicitly in `locales:`, or turn off `strict:` (default). Underlying: #{e.message.lines.first.strip}"
                )
              else
                UI.important(
                  "DevNotes: skipping 'values-#{q}' — #{e.message.lines.first.strip} " \
                  "(Pass `strict: true` to hard-fail instead of skipping, or map it in `qualifier_overrides`.)"
                )
                skipped << { qualifier: "values-#{q}", reason: e.reason }
              end
            else  # :malformed — genuinely not a locale (values-night, values-w720dp, etc.); skip regardless of strict.
              UI.important(
                "DevNotes: skipping 'values-#{q}' — #{e.message.lines.first.strip}"
              )
              skipped << { qualifier: "values-#{q}", reason: e.reason }
            end
          end
        end
        pairs
      end

      # --- IO --------------------------------------------------------------

      def self.write_utf8(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "wb") do |f|
          f.write(content.to_s.dup.force_encoding(Encoding::UTF_8))
        end
      end

      def self.finalize(written, skipped)
        result = {
          locales: written[:locales] || [],
          paths: written[:paths] || [],
          skipped: skipped
        }
        Actions.lane_context[SharedValues::DEVNOTES_PLAY_CHANGELOG_PATHS] = result
        result
      end

      # --- fastlane plugin metadata ----------------------------------------

      def self.description
        "Fetch per-locale DevNotes format outputs and write them as Google Play Store changelogs into the supply metadata tree."
      end

      def self.details
        <<~DETAILS
          For each locale in scope, fetches the chosen DevNotes format
          (defaults to 'play-store-changelog') and writes it to
          fastlane/metadata/android/<play_store_locale>/changelogs/<version_code>.txt
          — the path `supply` (a.k.a. upload_to_play_store) expects.

          Two locale discovery modes:
            1. Explicit `locales: ["en-US", "ru-RU", ...]` — operator
               controls the set verbatim.
            2. Auto-discovery (default): scan <res_path>/values-*/ for
               directories — the canonical Android "we ship this
               language" signal (the resource compiler pulls a locale
               into the AAB iff values-<qualifier>/ exists). Each
               qualifier (values-ru, values-pt-rBR, etc.) maps to a
               BCP 47 code and then to a Play Store metadata locale.
               Non-locale qualifiers (values-night, values-mdpi,
               values-w720dp, …) fall through and skip. Bare `values/`
               (default qualifier) is skipped — add to `locales:` if
               you want it.

          Run BEFORE upload_to_play_store(skip_upload_apk: true) so
          supply picks up the metadata tree in the same push.

          The DevNotes backend handles per-locale translation,
          max_char_length retry-to-fit, and caching by
          (format_id, commit_hash, model, prompt_hash). Editing the
          format's prompt in the UI produces a fresh cache row.
        DETAILS
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :api_url,
            env_name: "DEVNOTES_API_URL",
            description: "Base URL of the DevNotes REST API",
            optional: true,
            default_value: DEFAULT_API_URL,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :api_key,
            env_name: "DEVNOTES_API_KEY",
            description: "DevNotes API key (Bearer token)",
            sensitive: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :project_slug,
            env_name: "DEVNOTES_PROJECT_SLUG",
            description: (
              "Recommended. Project identifier in '<owner_username>/<slug>' form " \
              "or bare '<slug>' (mutually exclusive with project_name)"
            ),
            optional: true,
            conflicting_options: [:project_name],
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :project_name,
            env_name: "DEVNOTES_PROJECT_NAME",
            description: "DEPRECATED display name (mutually exclusive with project_slug)",
            optional: true,
            conflicting_options: [:project_slug],
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :release_name,
            env_name: "DEVNOTES_RELEASE_NAME",
            description: "Release name (e.g. '2.3.0-beta1'); defaults to last_git_tag",
            optional: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :from_tag,
            env_name: "DEVNOTES_FROM_TAG",
            description: "Git tag to compare from; if omitted, the API auto-detects from the production store",
            optional: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :format_slug,
            env_name: "DEVNOTES_PLAY_FORMAT_SLUG",
            description: (
              "DevNotes format slug to fetch per locale. Defaults to " \
              "'play-store-changelog' — define the format in the DevNotes UI " \
              "with max_char_length=480 (Play Store's hard 500-char limit minus " \
              "translation expansion buffer) and a plain-text + emoji prompt"
            ),
            optional: true,
            default_value: DEFAULT_FORMAT_SLUG,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :version_code,
            env_name: "DEVNOTES_PLAY_VERSION_CODE",
            description: (
              "Android versionCode the changelog attaches to (must match the build " \
              "supply uploads). Integer or String of digits — both accepted; intentionally " \
              "permissive because operators often forward from android_get_version_code"
            )
            # No `type:` — permissive Integer-or-String; validated imperatively in run.
          ),
          FastlaneCore::ConfigItem.new(
            key: :locales,
            env_name: "DEVNOTES_PLAY_LOCALES",
            description: (
              "Optional explicit BCP 47 locale list (e.g. ['en-US', 'ru-RU']). When " \
              "set, res_path is NOT inspected. When unset (default), the action " \
              "auto-discovers from <res_path>/values-*/ directories (the canonical Android shipped-languages signal)"
            ),
            optional: true,
            type: Array
          ),
          FastlaneCore::ConfigItem.new(
            key: :res_path,
            env_name: "DEVNOTES_PLAY_RES_PATH",
            description: (
              "Root of the Android resource directory (containing values-*/ " \
              "dirs) to scan when auto-discovering locales. Ignored when " \
              "`locales:` is set. Relative paths resolve from the project root, " \
              "not Dir.pwd. Default is the AGP layout; module-root / flat " \
              "Gradle layouts should pass `res_path: \"res\"`"
            ),
            optional: true,
            default_value: DEFAULT_RES_PATH,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :metadata_path,
            env_name: "DEVNOTES_PLAY_METADATA_PATH",
            description: (
              "Root of the supply metadata tree; files land at " \
              "<metadata_path>/<play_store_locale>/changelogs/<version_code>.txt. " \
              "Relative paths resolve from the project root"
            ),
            optional: true,
            default_value: DEFAULT_METADATA_PATH,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :locale_overrides,
            env_name: "DEVNOTES_PLAY_LOCALE_OVERRIDES",
            description: (
              "Optional Hash rewriting BCP 47 → Play Store metadata codes (e.g. " \
              "{ 'es-MX' => 'es-MX' } to override the default es-419 collapse). " \
              "Applied AFTER the built-in quirks pass. NOTE: this leg runs " \
              "AFTER qualifier_to_bcp47 — so it cannot rescue ambiguous " \
              "bare-language qualifiers (pt/zh/es). Use `qualifier_overrides:` " \
              "for that; use `locale_overrides:` only to remap a resolved BCP 47 " \
              "code onto a different Play Store listing"
            ),
            optional: true,
            type: Hash
          ),
          FastlaneCore::ConfigItem.new(
            key: :qualifier_overrides,
            env_name: "DEVNOTES_PLAY_QUALIFIER_OVERRIDES",
            description: (
              "Optional Hash rewriting Android resource qualifier → BCP 47 " \
              "(e.g. { 'pt' => 'pt-PT', 'es' => 'es-419', 'fa' => 'fa' }). " \
              "Consulted FIRST inside qualifier_to_bcp47, before any built-in " \
              "rule — so this is the escape hatch for ambiguous bare-language " \
              "cases (pt/zh/es) that would otherwise hard-fail AND for unmapped " \
              "bare-languages (fa, hy, etc.) that would otherwise silently skip. " \
              "Auto-discovery mode only (ignored when `locales:` is set)"
            ),
            optional: true,
            type: Hash
          ),
          FastlaneCore::ConfigItem.new(
            key: :strict,
            env_name: "DEVNOTES_PLAY_STRICT",
            description: (
              "When true, an Android qualifier the plugin can't map (e.g. a " \
              "language code not in BARE_LANGUAGE_DEFAULTS) HARD-FAILS the " \
              "build instead of silently skipping the locale. Recommended for " \
              "production so a supported language never vanishes from a " \
              "release when a translator adds a new values-<lang>/ dir. Genuinely " \
              "non-locale qualifiers (values-night, values-v21, values-mdpi, values-w720dp) still skip " \
              "regardless of this flag. Auto-discovery mode only"
            ),
            optional: true,
            default_value: false,
            is_string: false,
            type: Boolean
          ),
          FastlaneCore::ConfigItem.new(
            key: :poll_interval,
            env_name: "DEVNOTES_POLL_INTERVAL",
            description: "Seconds between job-status polls",
            optional: true,
            default_value: 10,
            type: Integer
          ),
          FastlaneCore::ConfigItem.new(
            key: :timeout,
            env_name: "DEVNOTES_TIMEOUT",
            description: "Total seconds to wait for generation before failing",
            optional: true,
            default_value: 600,
            type: Integer
          )
        ]
      end

      def self.output
        [
          ["DEVNOTES_PLAY_CHANGELOG_PATHS", "Hash with :locales, :paths, :skipped — see return_value"]
        ]
      end

      def self.return_value
        "Hash: { locales: [...], paths: [...], skipped: [...] }. " \
          "Also stored in lane_context[SharedValues::DEVNOTES_PLAY_CHANGELOG_PATHS]."
      end

      def self.authors
        ["Jason Byteforge (@jmazzahacks)"]
      end

      def self.is_supported?(platform)
        [:android].include?(platform)
      end
    end
  end
end
