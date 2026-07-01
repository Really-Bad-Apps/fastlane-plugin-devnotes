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
        # `<res_path>/raw*` and map qualifiers to BCP 47. The bonus dedup
        # for "both raw-pt and raw-pt-rBR exist" lives in build_pairs_from_res_path.
        skipped = []
        pairs = if params[:locales].is_a?(Array) && !params[:locales].empty?
          build_pairs_from_explicit(params[:locales], overrides)
        else
          build_pairs_from_res_path(
            File.expand_path(params[:res_path], project_root),
            overrides,
            skipped
          )
        end

        if pairs.empty?
          UI.important(
            "DevNotes: no locales to write — pass `locales: [...]` explicitly " \
            "or populate res/raw-*/ via devnotes_fetch_inline first."
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

      # Auto-discovery: walk <res_path>/raw* directories. For each, map
      # the qualifier to BCP 47, then to a Play Store code. Skip `raw/`
      # (default qualifier) with a one-line UI.important rather than
      # guessing en-US — that guess silently writes the wrong file when
      # the app's default language isn't English.
      def self.build_pairs_from_res_path(res_path, overrides, skipped)
        unless File.directory?(res_path)
          UI.important(
            "DevNotes: res_path '#{res_path}' is not a directory — nothing to auto-discover. " \
            "Pass `locales: [...]` explicitly or set res_path to your AGP source tree."
          )
          return []
        end

        # Gather every raw-* dir; record bare `raw/` as skipped.
        qualifiers = []
        Dir.children(res_path).each do |entry|
          full = File.join(res_path, entry)
          next unless File.directory?(full)
          if entry == "raw"
            UI.important(
              "DevNotes: found '#{res_path}/raw/' (default Android qualifier) — skipping. " \
              "Add the desired locale (e.g. 'en-US') to `locales: [...]` if you want it included."
            )
            skipped << { qualifier: "raw", reason: "default qualifier — add to locales: explicitly" }
            next
          end
          if entry.start_with?("raw-")
            qualifiers << entry.sub(/\Araw-/, "")
          end
        end

        # Dedup: if both `pt` and `pt-rBR` are present, the region-qualified
        # version wins (it's MORE specific, not ambiguous-vs-it). Strip the
        # bare-language form so we don't emit two writes that target the
        # same Play Store locale.
        qualified_langs = qualifiers
          .select { |q| q.include?("-r") }
          .map { |q| q.split("-r", 2).first }
        qualifiers.reject! do |q|
          if !q.include?("-r") && !q.start_with?("b+") && qualified_langs.include?(q)
            skipped << { qualifier: "raw-#{q}", reason: "shadowed by a more-specific raw-#{q}-r<REGION>" }
            true
          else
            false
          end
        end

        # Map each qualifier individually. Non-locale Android qualifiers
        # (raw-night, raw-v21, raw-car, raw-mcc310, …) produce :unknown
        # or :malformed UnmappableQualifierError and are skipped with a
        # warning so the lane keeps going. AMBIGUOUS bare-languages (pt,
        # zh, es) hard-fail because the operator clearly meant a locale
        # and needs to disambiguate.
        pairs = []
        qualifiers.sort.each do |q|
          begin
            bcp47 = Helper::DevnotesLocaleMap.qualifier_to_bcp47(q)
            play_store = Helper::DevnotesLocaleMap.bcp47_to_play_store(bcp47, overrides: overrides)
            pairs << [bcp47, play_store]
          rescue Helper::DevnotesLocaleMap::UnmappableQualifierError => e
            case e.reason
            when :ambiguous
              UI.user_error!("DevNotes: #{e.message}")
            else  # :unknown or :malformed — non-locale qualifier, skip
              UI.important(
                "DevNotes: skipping 'raw-#{q}' — #{e.message.lines.first.strip}"
              )
              skipped << { qualifier: "raw-#{q}", reason: e.reason }
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
            2. Auto-discovery (default): scan <res_path>/raw-*/ for
               directories. Each Android resource qualifier (raw-ru,
               raw-pt-rBR, etc.) maps to a BCP 47 code and then to a
               Play Store metadata locale. The bare `raw/` qualifier
               is skipped — add to `locales:` if you want it.

          Run AFTER devnotes_fetch_inline (which populates the raw-*
          tree) and BEFORE upload_to_play_store(skip_upload_apk: true).

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
              "auto-discovers from <res_path>/raw-*/ directories"
            ),
            optional: true,
            type: Array
          ),
          FastlaneCore::ConfigItem.new(
            key: :res_path,
            env_name: "DEVNOTES_PLAY_RES_PATH",
            description: (
              "Android resource directory to scan when auto-discovering locales " \
              "(ignored when `locales:` is set). Relative paths resolve from the " \
              "project root, not Dir.pwd"
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
              "Applied AFTER the built-in quirks pass"
            ),
            optional: true,
            type: Hash
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
