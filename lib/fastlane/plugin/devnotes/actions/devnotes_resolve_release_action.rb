require "fastlane/action"
require_relative "devnotes_fetch_inline_action"

module Fastlane
  module Actions
    class DevnotesResolveReleaseAction < Action
      def self.run(params)
        Helper::DevnotesActionMixin.require_project_identifier(params)
        release_name = Helper::DevnotesActionMixin.resolve_release_name(params)
        client = Helper::DevnotesHelper.new(
          api_url: params[:api_url], api_key: params[:api_key],
          poll_interval: params[:poll_interval], timeout: params[:timeout]
        )
        project = Helper::DevnotesActionMixin.resolve_project(client, params)
        owner, slug = project.values_at("created_by_username", "slug")
        if owner.nil? || slug.nil?
          UI.user_error!("DevNotes project #{project['id']} has no (created_by_username, slug) pair.")
        end
        Helper::DevnotesActionMixin.generate_release(client, owner, slug, release_name, params[:from_tag])
      rescue Helper::DevnotesHelper::ApiError => e
        UI.user_error!("DevNotes API error: #{e.message}")
      end

      def self.available_options
        keys = [:api_url, :api_key, :project_slug, :project_name, :release_name, :from_tag, :poll_interval, :timeout]
        DevnotesFetchInlineAction.available_options.select { |option| keys.include?(option.key) }
      end

      def self.description
        "Generate release notes once and return the release ID for all format and locale fetches."
      end

      def self.details
        "Call once before the locale loop. Pass the returned positive integer as release_id to " \
          "devnotes_fetch_inline and devnotes_write_play_changelogs. Each call to this action generates " \
          "a release; it does not reuse a hidden process-wide cache."
      end

      def self.return_value
        "The completed release ID (Integer)."
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
