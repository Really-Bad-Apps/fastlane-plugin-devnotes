module Fastlane
  module Helper
    # Shared orchestration extracted from devnotes_fetch_inline_action.rb
    # so both actions in this gem can call the same project-resolution +
    # submit-and-poll flow. Module functions only (NOT extended into the
    # action classes) — keeps RSpec stub scope explicit and avoids
    # cross-action method-table leakage.
    #
    # The split with Helper::DevnotesHelper: that class wraps the raw
    # HTTP surface and raises typed errors. This module wraps the
    # action-layer orchestration on top — it CAN call FastlaneCore::UI
    # and Actions::LastGitTagAction because it's expected to run inside
    # a fastlane lane. Helper::DevnotesHelper stays UI-free.
    module DevnotesActionMixin
      # Falls back to last_git_tag if release_name isn't passed. Lives in
      # the mixin (not the action) because both actions need it and the
      # LastGitTagAction call is the same pattern in both.
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

      # Precedence: project_slug (the recommended path) wins, then
      # project_name (deprecated). Mutual exclusivity is enforced by
      # ConfigItem's conflicting_options on each action; this method
      # only cares about which one is set.
      #
      # Returns the FULL project hash from the API (id, slug,
      # created_by_username, etc.) — both actions need the owner+slug
      # pair to address every project-scoped endpoint.
      def self.resolve_project(client, params)
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

      # Returns the job hash on completion. Hard-fails if the API returns
      # no job_id, if the job reports failed, or if the poll exceeds the
      # client's configured timeout.
      def self.submit_and_wait(client, owner_username, project_slug, release_name, from_tag)
        UI.message("DevNotes: submitting generation job...")
        submission = client.submit_generation_job(
          owner_username: owner_username,
          project_slug: project_slug,
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
      # only checks the "neither set" case, which fastlane doesn't model.
      def self.require_project_identifier(params)
        return if params[:project_slug] && !params[:project_slug].to_s.strip.empty?
        return if params[:project_name] && !params[:project_name].to_s.strip.empty?
        UI.user_error!(
          "DevNotes: provide project_slug (recommended) or project_name (deprecated)."
        )
      end

      # Resolve relative paths against the project root (the parent of
      # fastlane/), not Dir.pwd. Fastlane chdir's into the fastlane/
      # folder before running a lane, so File.expand_path(rel) would
      # otherwise silently place files under fastlane/ instead of the
      # AGP source tree. Falls back to Dir.pwd when no Fastfile is in
      # play (bare CLI usage).
      def self.project_root
        fastlane_folder = FastlaneCore::FastlaneFolder.path if defined?(FastlaneCore::FastlaneFolder)
        return Dir.pwd if fastlane_folder.nil?
        File.expand_path("..", fastlane_folder)
      end
    end
  end
end
