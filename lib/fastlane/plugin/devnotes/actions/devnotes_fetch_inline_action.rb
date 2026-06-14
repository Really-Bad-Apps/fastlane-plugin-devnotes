require "fastlane/action"
require "fileutils"
require_relative "../helper/devnotes_helper"

module Fastlane
  module Actions
    class DevnotesFetchInlineAction < Action
      DEFAULT_API_URL = "https://api.devnotes.ai".freeze
      DEFAULT_OUTPUT_PATH = "app/src/main/res/raw/rnotes.txt".freeze
      # Matches /res/raw/ and Android resource qualifier variants like
      # /res/raw-en/, /res/raw-night/, /res/raw-v21/.
      RES_RAW_DIR_PATTERN = %r{/res/raw(?:-[a-z0-9_\-]+)?/}.freeze
      RES_RAW_NAME_PATTERN = /\A[a-z0-9_.]+\z/.freeze

      def self.run(params)
        require_project_identifier(params)

        release_name = resolve_release_name(params)
        output_path = File.expand_path(params[:output_path], project_root)
        validate_res_raw_filename(output_path)

        format_slug = params[:format_slug].to_s.strip
        UI.user_error!("format_slug must not be empty") if format_slug.empty?

        client = Helper::DevnotesHelper.new(
          api_url: params[:api_url],
          api_key: params[:api_key],
          poll_interval: params[:poll_interval],
          timeout: params[:timeout]
        )

        project = resolve_project(client, params)
        project_id = project["id"]
        owner_username = project["created_by_username"]
        project_slug_value = project["slug"]
        if owner_username.nil? || project_slug_value.nil?
          # Backend hasn't backfilled (owner_username, slug) on this row yet
          # — without those, the lazy format endpoint isn't addressable.
          UI.user_error!(
            "DevNotes project #{project_id} has no (created_by_username, slug) pair " \
            "— ask your DevNotes admin to backfill it before re-running this lane."
          )
        end
        UI.message(
          "DevNotes: project=#{owner_username}/#{project_slug_value} (id=#{project_id}) " \
          "release_name=#{release_name} format_slug=#{format_slug}"
        )

        job = submit_and_wait(client, project_id, release_name, params[:from_tag])

        release_id = (job["result_data"] || {})["release_id"]
        unless release_id.is_a?(Integer) && release_id.positive?
          UI.user_error!(
            "Job #{job['id']} completed but result_data.release_id is missing or invalid " \
            "(got #{release_id.inspect}). This usually means the DevNotes backend is older " \
            "than v89 (the formats redesign); upgrade the backend and retry."
          )
        end

        UI.message("DevNotes: fetching format '#{format_slug}' for release #{release_id}...")
        output = client.get_format_output(
          owner_username: owner_username,
          project_slug: project_slug_value,
          release_id: release_id,
          format_slug: format_slug
        )

        content = output["content"]
        unless content.is_a?(String) && !content.empty?
          UI.user_error!(
            "Format '#{format_slug}' returned empty content (got #{content.class}). " \
            "Check the format's prompt in the DevNotes UI."
          )
        end

        write_utf8(output_path, content)
        mime_type = output["mime_type"] || "(unknown)"
        UI.success(
          "DevNotes: wrote #{content.bytesize} bytes (#{mime_type}) to #{output_path}"
        )
        output_path
      rescue Helper::DevnotesHelper::AmbiguousSlugError => e
        # Specific catch first (subclass of ApiError) so we can format the
        # candidates list with copy-paste-ready project_slug values.
        lines = ["DevNotes: #{e.message}", "Re-run with the explicit owner/slug form:"]
        e.candidates.each do |c|
          lines << "  project_slug: \"#{c['owner_username']}/#{c['slug']}\""
        end
        UI.user_error!(lines.join("\n"))
      rescue Helper::DevnotesHelper::ApiError => e
        # Single rescue at the top of run() so every helper call gets
        # uniform UI.user_error! translation, including project lookup
        # (which used to escape as a raw stack trace on a 404) and the
        # new lazy format-output endpoint (422 on prompt template errors,
        # 503 on transient LLM failures retried up to MAX_CONSECUTIVE_TRANSIENT_ERRORS).
        UI.user_error!("DevNotes API error: #{e.message}")
      end

      def self.resolve_release_name(params)
        explicit = params[:release_name]
        return explicit unless explicit.nil? || explicit.to_s.strip.empty?

        UI.message("DevNotes: no release_name given, resolving from last_git_tag")
        tag = begin
          Actions::LastGitTagAction.run({}).to_s.strip
        rescue StandardError => e
          UI.user_error!("Could not resolve release_name from last_git_tag: #{e.message}")
        end
        UI.user_error!("Could not determine a release_name from last_git_tag (no tags reachable from HEAD).") if tag.empty?
        tag
      end

      # Precedence: explicit project_id wins, then project_slug (the
      # recommended path), then project_name (deprecated). Mutual exclusivity
      # is enforced by ConfigItem's conflicting_options; this method only
      # cares about which one is set.
      #
      # Returns the FULL project hash from the API (id, slug,
      # created_by_username, etc.) — the action needs the owner+slug pair
      # to address the lazy format-output endpoint, so every path resolves
      # to a project hash including those fields.
      def self.resolve_project(client, params)
        return client.get_project(params[:project_id]) if params[:project_id]

        slug = params[:project_slug]
        if slug && !slug.to_s.strip.empty?
          if slug.include?("/")
            owner_username, slug_value = slug.split("/", 2)
            return client.get_project_by_owner_and_slug(owner_username, slug_value)
          end
          return client.get_project_by_slug(slug)
        end

        client.get_project_by_name(params[:project_name])
      end

      def self.submit_and_wait(client, project_id, release_name, from_tag)
        UI.message("DevNotes: submitting generation job...")
        submission = client.submit_generation_job(
          project_id: project_id,
          release_name: release_name,
          from_tag: from_tag
        )
        job_id = submission["job_id"]
        UI.user_error!("DevNotes API returned no job_id from submit: #{submission.inspect}") if job_id.nil?

        UI.message("DevNotes: job #{job_id} submitted; polling until complete (timeout: #{client.timeout}s)...")
        job = client.poll_until_terminal(job_id)

        if job["status"] == "failed"
          UI.user_error!("DevNotes job #{job_id} failed: #{job['error_message']}")
        end
        job
      end

      # "Both set" is enforced by ConfigItem's conflicting_options. This
      # only checks the "neither set" case, which Fastlane doesn't model.
      def self.require_project_identifier(params)
        return if params[:project_id]
        return if params[:project_slug] && !params[:project_slug].to_s.strip.empty?
        return if params[:project_name] && !params[:project_name].to_s.strip.empty?
        UI.user_error!(
          "DevNotes: provide one of project_slug (recommended), project_id, " \
          "or project_name (deprecated)."
        )
      end

      # Resolve relative output_path against the project root (the parent of
      # fastlane/), not Dir.pwd. Fastlane chdir's into the fastlane/ folder
      # before running a lane, so File.expand_path(rel) would otherwise
      # silently place files under fastlane/ instead of the AGP source tree.
      # Falls back to Dir.pwd when no Fastfile is in play (bare CLI usage).
      def self.project_root
        fastlane_folder = FastlaneCore::FastlaneFolder.path if defined?(FastlaneCore::FastlaneFolder)
        return Dir.pwd if fastlane_folder.nil?
        File.expand_path("..", fastlane_folder)
      end

      def self.validate_res_raw_filename(output_path)
        return unless output_path =~ RES_RAW_DIR_PATTERN
        basename = File.basename(output_path)
        return if basename =~ RES_RAW_NAME_PATTERN
        UI.user_error!(
          "output_path '#{output_path}' targets res/raw/ but '#{basename}' is not a valid " \
          "Android resource name. res/raw filenames must match [a-z0-9_.]+ (no uppercase, no hyphens)."
        )
      end

      def self.write_utf8(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "wb") do |f|
          f.write(content.to_s.dup.force_encoding(Encoding::UTF_8))
        end
      end

      def self.description
        "Generate and fetch a DevNotes release-notes format; write the bytes to a path in the Android source tree."
      end

      def self.details
        <<~DETAILS
          Submits a release-notes generation job to the DevNotes API, polls
          until it completes, then lazily fetches the chosen format's output
          for that release and writes it to the given path. Intended to run
          before `gradle assembleRelease` so the notes are bundled as an
          Android resource (e.g. app/src/main/res/raw/rnotes.txt).

          Pick which output to bundle with `format_slug:` — defaults to
          'mobile-html' (the standard Android notes format). Other formats
          (X posts, WordPress blog, Play Store notes, etc.) are user-defined
          per project in the DevNotes web UI.

          The DevNotes backend caches each format's output by (format_id,
          commit_hash, model, prompt_hash). Rebuilding the same tag with the
          same prompt short-circuits the LLM and returns instantly; editing
          the prompt in the UI produces a fresh cache row on the next build.

          Auth: Bearer token in the Authorization header (DEVNOTES_API_KEY).
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
              "Recommended. Project identifier in the GitHub-style " \
              "'<owner_username>/<slug>' form (e.g. 'byteforge/podcast-guru-android'), " \
              "or bare '<slug>' when unambiguous across your projects (mutually " \
              "exclusive with project_name and project_id)"
            ),
            optional: true,
            conflicting_options: [:project_name, :project_id],
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :project_name,
            env_name: "DEVNOTES_PROJECT_NAME",
            description: (
              "DEPRECATED — names are mutable display text and break builds " \
              "on rename; prefer project_slug (mutually exclusive with " \
              "project_slug and project_id)"
            ),
            optional: true,
            conflicting_options: [:project_slug, :project_id],
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :project_id,
            env_name: "DEVNOTES_PROJECT_ID",
            description: (
              "DevNotes project id (mutually exclusive with project_slug " \
              "and project_name)"
            ),
            optional: true,
            conflicting_options: [:project_slug, :project_name],
            type: Integer
          ),
          FastlaneCore::ConfigItem.new(
            key: :format_slug,
            env_name: "DEVNOTES_FORMAT_SLUG",
            description: (
              "Which DevNotes format to bundle. Defaults to 'mobile-html' " \
              "(the standard Android notes format). Define additional " \
              "formats — X posts, WordPress blog, Play Store notes, etc. — " \
              "in the DevNotes web UI and reference them here"
            ),
            optional: true,
            default_value: "mobile-html",
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
            key: :output_path,
            env_name: "DEVNOTES_OUTPUT_PATH",
            description: "Where to write the mobile notes (relative to the Fastfile's CWD)",
            optional: true,
            default_value: DEFAULT_OUTPUT_PATH,
            type: String
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

      def self.return_value
        "Absolute path of the file that was written."
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
