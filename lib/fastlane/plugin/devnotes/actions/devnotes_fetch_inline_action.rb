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
        require_project_id_or_name(params)

        release_name = resolve_release_name(params)
        output_path = File.expand_path(params[:output_path], project_root)
        validate_res_raw_filename(output_path)

        client = Helper::DevnotesHelper.new(
          api_url: params[:api_url],
          api_key: params[:api_key],
          poll_interval: params[:poll_interval],
          timeout: params[:timeout]
        )

        project_id = resolve_project_id(client, params)
        UI.message("DevNotes: project_id=#{project_id} release_name=#{release_name}")

        job = submit_and_wait(client, project_id, release_name, params[:from_tag])

        result_data = job["result_data"] || {}
        mobile_notes = result_data["mobile_notes"]
        unless mobile_notes.is_a?(String) && !mobile_notes.empty?
          UI.user_error!(
            "Job #{job['id']} completed but result_data.mobile_notes is empty or " \
            "not a string (got #{mobile_notes.class})."
          )
        end

        write_utf8(output_path, mobile_notes)
        UI.success("DevNotes: wrote #{mobile_notes.bytesize} bytes to #{output_path}")
        output_path
      rescue Helper::DevnotesHelper::ApiError => e
        # Single rescue at the top of run() so every helper call gets
        # uniform UI.user_error! translation, including project lookup
        # (which used to escape as a raw stack trace on a 404).
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

      def self.resolve_project_id(client, params)
        return params[:project_id] if params[:project_id]

        project = client.get_project_by_name(params[:project_name])
        id = project["id"]
        UI.user_error!("API returned no id for project '#{params[:project_name]}'") if id.nil?
        id
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
      def self.require_project_id_or_name(params)
        return if params[:project_id]
        return if params[:project_name] && !params[:project_name].to_s.strip.empty?
        UI.user_error!("DevNotes: provide either project_id or project_name.")
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
        "Generate and fetch DevNotes mobile release notes; write the HTML to a path in the Android source tree."
      end

      def self.details
        <<~DETAILS
          Submits a release-notes generation job to the DevNotes API, polls until it
          completes, and writes the mobile HTML variant from result_data.mobile_notes
          to the given path. Intended to run before `gradle assembleRelease` so the
          notes are bundled as an Android resource (e.g. app/src/main/res/raw/rnotes.txt).

          The DevNotes backend caches release notes by (project_id, commit_hash, model)
          — rebuilding the same tag short-circuits the LLM and returns instantly.

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
            key: :project_name,
            env_name: "DEVNOTES_PROJECT_NAME",
            description: "DevNotes project name (mutually exclusive with project_id)",
            optional: true,
            conflicting_options: [:project_id],
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :project_id,
            env_name: "DEVNOTES_PROJECT_ID",
            description: "DevNotes project id (mutually exclusive with project_name)",
            optional: true,
            conflicting_options: [:project_name],
            type: Integer
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
