require "net/http"
require "uri"
require "json"
require "openssl"

module Fastlane
  module Helper
    # HTTP client for the DevNotes REST API.
    #
    # Hand-rolled on Ruby stdlib (net/http + json) so this plugin has zero
    # runtime gem dependencies inside consumer Pluginfiles. All public
    # operations (project lookup, submit, poll) share one transient-retry
    # policy via with_transient_retry: fail-fast on 4xx and on contract
    # errors, retry up to MAX_CONSECUTIVE_TRANSIENT_ERRORS on 5xx and
    # network errors.
    class DevnotesHelper
      class ApiError < StandardError
        attr_reader :code

        def initialize(message, code: nil)
          super(message)
          @code = code
        end
      end

      # Raised when GET /api/projects/by-slug/<slug> returns 409 because more
      # than one accessible project shares the slug across different owners.
      # `candidates` is an array of {"owner_username" => ..., "slug" => ...}
      # hashes — re-call with the explicit owner/slug form to disambiguate.
      #
      # Subclasses ApiError so the existing `rescue ApiError` paths in the
      # action keep catching it; the action narrows with `rescue AmbiguousSlugError`
      # to format the candidate list specifically.
      class AmbiguousSlugError < ApiError
        attr_reader :candidates

        def initialize(message, candidates:)
          super(message, code: 409)
          @candidates = candidates
        end
      end

      MAX_CONSECUTIVE_TRANSIENT_ERRORS = 6
      OPEN_TIMEOUT_SECONDS = 30
      READ_TIMEOUT_SECONDS = 60

      attr_reader :poll_interval, :timeout

      def initialize(api_url:, api_key:, poll_interval: 10, timeout: 600)
        raise ArgumentError, "api_url is required" if api_url.nil? || api_url.to_s.empty?
        raise ArgumentError, "api_key is required" if api_key.nil? || api_key.to_s.empty?
        raise ArgumentError, "poll_interval must be > 0" unless poll_interval.to_i > 0
        raise ArgumentError, "timeout must be > 0" unless timeout.to_i > 0

        # Ensure exactly one trailing slash so URI#merge preserves any
        # path prefix the user included (e.g. https://gateway.example/devnotes/).
        normalized = api_url.to_s.sub(%r{/*\z}, "/")
        @base_uri = URI.parse(normalized)
        @api_key = api_key
        @poll_interval = poll_interval
        @timeout = timeout
        @http = nil
      end

      def get_project_by_name(name)
        with_transient_retry { get("/api/projects/by-name/#{path_segment(name)}") }
      end

      # Resolve a project by numeric id. Used when the Fastfile passes
      # project_id: directly — we still need the project's
      # (created_by_username, slug) pair to call the new format-output
      # endpoint, so the action fetches the project regardless of which
      # identifier the caller supplied.
      def get_project(project_id)
        with_transient_retry { get("/api/projects/#{path_segment(project_id)}") }
      end

      # Resolve a project by bare slug; relies on the backend to 404 if no
      # accessible project matches and to 409 (→ AmbiguousSlugError) if more
      # than one accessible project shares the slug across owners.
      def get_project_by_slug(slug)
        with_transient_retry { get("/api/projects/by-slug/#{path_segment(slug)}") }
      end

      # Resolve a project by the explicit `(owner_username, slug)` identifier.
      # Use this directly when both values are known up-front (e.g. from a
      # Fastfile), or as the disambiguation step after AmbiguousSlugError.
      def get_project_by_owner_and_slug(owner_username, slug)
        with_transient_retry do
          get("/api/projects/by-slug/#{path_segment(owner_username)}/#{path_segment(slug)}")
        end
      end

      # Lazy GET (or generate-and-cache) a format's output for a release.
      # Backend cache key: (format_id, commit_hash, model, prompt_hash) —
      # so identical builds against the same tag short-circuit the LLM
      # and return cached bytes. Editing the format's prompt produces a
      # fresh prompt_hash → cache miss → regeneration on the next call.
      #
      # Response shape: { format_slug, content, mime_type, model,
      #   prompt_hash, generated_at } — `content` is the bytes to bundle.
      def get_format_output(owner_username:, project_slug:, release_id:, format_slug:)
        with_transient_retry do
          get(
            "/api/projects/#{path_segment(owner_username)}/#{path_segment(project_slug)}" \
            "/releases/#{path_segment(release_id)}/formats/#{path_segment(format_slug)}"
          )
        end
      end

      def submit_generation_job(project_id:, release_name:, from_tag: nil)
        body = { release_name: release_name }
        # Empty string is truthy in Ruby — guard explicitly so an empty
        # DEVNOTES_FROM_TAG env var doesn't override the backend's auto-detect.
        body[:from_tag] = from_tag if from_tag && !from_tag.to_s.strip.empty?
        with_transient_retry { post("/api/projects/#{project_id}/generate-release-notes", body) }
      end

      # Poll /api/jobs/<job_id> until status is terminal (completed | failed)
      # or @timeout elapses. Returns the final job hash.
      # Uses one persistent HTTP session across polls so we don't pay a
      # TLS handshake every @poll_interval seconds.
      def poll_until_terminal(job_id)
        deadline = monotonic_time + @timeout
        with_persistent_session do
          loop do
            if monotonic_time >= deadline
              raise ApiError.new("Timed out after #{@timeout}s waiting for job #{job_id}")
            end

            job = with_transient_retry { get("/api/jobs/#{job_id}") }
            status = job["status"]
            return job if status == "completed" || status == "failed"

            sleep(@poll_interval)
          end
        end
      end

      private

      def get(path)
        request(Net::HTTP::Get.new(uri_for(path).request_uri))
      end

      def post(path, body)
        req = Net::HTTP::Post.new(uri_for(path).request_uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        request(req)
      end

      def request(req)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Accept"] = "application/json"

        response = perform_request(req)
        code = response.code.to_i
        return parse_body(response) if code >= 200 && code < 300

        # Detect the slug-ambiguity 409: GET /api/projects/by-slug/<slug>
        # returns a candidates array when more than one accessible project
        # shares the slug. Lift it into a typed error so the action can
        # format the choices without re-parsing the response body.
        if code == 409
          parsed = parse_error_json(response)
          if parsed.is_a?(Hash) && parsed["candidates"].is_a?(Array)
            raise AmbiguousSlugError.new(
              parsed["message"] || "Ambiguous slug",
              candidates: parsed["candidates"]
            )
          end
        end

        raise ApiError.new("HTTP #{code}: #{extract_error_message(response)}", code: code)
      end

      # Best-effort JSON parse of an error response body; returns nil on
      # parse failure or empty body. Used to peek at structured error
      # payloads (e.g. the 409 candidates list) without raising — the
      # generic ApiError path still surfaces unparsed bodies via
      # extract_error_message.
      def parse_error_json(response)
        body = response.body.to_s
        return nil if body.empty?
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def perform_request(req)
        if @http
          begin
            return @http.request(req)
          rescue Errno::ECONNRESET, EOFError, Errno::EPIPE
            # Persistent session went stale — server closed its end between
            # polls. Drop the dead session and fall through to a fresh open.
            @http = nil
          end
        end

        Net::HTTP.start(
          @base_uri.host,
          @base_uri.port,
          use_ssl: @base_uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT_SECONDS,
          read_timeout: READ_TIMEOUT_SECONDS
        ) do |http|
          http.request(req)
        end
      end

      # Hold one Net::HTTP session open across multiple requests so the
      # poll loop reuses one TCP/TLS connection. keep_alive_timeout is
      # padded above @poll_interval so the client doesn't close between
      # polls; if the server closes its end, perform_request falls back
      # to a fresh connection.
      def with_persistent_session
        Net::HTTP.start(
          @base_uri.host,
          @base_uri.port,
          use_ssl: @base_uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT_SECONDS,
          read_timeout: READ_TIMEOUT_SECONDS,
          keep_alive_timeout: @poll_interval * 2
        ) do |http|
          @http = http
          yield
        end
      ensure
        @http = nil
      end

      # Wrap a block in fail-fast-on-4xx/contract-error, retry-on-5xx-or-network
      # policy. Sleeps @poll_interval between attempts. After
      # MAX_CONSECUTIVE_TRANSIENT_ERRORS, re-raises as an ApiError.
      def with_transient_retry
        consecutive_errors = 0
        begin
          return yield
        rescue ApiError => e
          # Fail-fast on permanent 4xx AND on nil-code (contract-error) ApiErrors —
          # those come from parse_body / shape mismatches, where retry can't help.
          raise if e.code.nil? || e.code < 500
          consecutive_errors += 1
          if consecutive_errors >= MAX_CONSECUTIVE_TRANSIENT_ERRORS
            raise ApiError.new(
              "Gave up after #{consecutive_errors} consecutive errors: #{e.message}",
              code: e.code
            )
          end
          sleep(@poll_interval)
          retry
        rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError, OpenSSL::SSL::SSLError => e
          consecutive_errors += 1
          if consecutive_errors >= MAX_CONSECUTIVE_TRANSIENT_ERRORS
            raise ApiError.new("Gave up after #{consecutive_errors} consecutive network errors: #{e.message}")
          end
          sleep(@poll_interval)
          retry
        end
      end

      def parse_body(response)
        body = response.body.to_s
        return {} if body.empty?
        parsed = JSON.parse(body)
        return parsed if parsed.is_a?(Hash)
        raise ApiError.new("Expected JSON object from API, got #{parsed.class}: #{body[0, 200]}")
      end

      def extract_error_message(response)
        body = response.body.to_s
        return response.message if body.empty?

        begin
          parsed = JSON.parse(body)
        rescue JSON::ParserError
          return body[0, 200]
        end

        return response.message unless parsed.is_a?(Hash)
        return parsed["message"] if parsed["message"].is_a?(String)
        return parsed["error"] if parsed["error"].is_a?(String)

        # flask-smorest validation: {"errors": {"json": {"field": ["msg", ...]}}}
        smorest = flatten_smorest_errors(parsed["errors"])
        return smorest if smorest

        response.message
      end

      def flatten_smorest_errors(errors)
        return nil unless errors.is_a?(Hash) && !errors.empty?

        pieces = []
        errors.each do |location, fields|
          if fields.is_a?(Hash)
            fields.each do |field, messages|
              messages = [messages] unless messages.is_a?(Array)
              pieces << "#{location}.#{field}: #{messages.join('; ')}"
            end
          else
            pieces << "#{location}: #{fields}"
          end
        end
        pieces.empty? ? nil : pieces.join(" | ")
      end

      def uri_for(path)
        # Strip leading slash so #merge concatenates onto the base path
        # (the base has a trailing slash from #initialize) instead of
        # replacing it. RFC 3986 reference-resolution.
        @base_uri.merge(path.to_s.sub(%r{\A/}, ""))
      end

      # Encode a single path segment. URI.encode_www_form_component is
      # form-encoding (spaces become "+"), but Flask path segments need "%20".
      def path_segment(value)
        URI.encode_www_form_component(value.to_s).gsub("+", "%20")
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
