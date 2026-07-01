require "spec_helper"
require "fileutils"
require "tmpdir"

# End-to-end WebMock-stubbed run of the action: tmp res/values-{en,ru,de}/
# tree (the canonical Android "we ship this language" signal), stubbed
# project lookup + submit + poll + 3 format-output calls, assertions on
# the supply metadata files written. Contract guard for the action —
# covers auto-discovery, per-locale write, and SharedValues lane-context.
RSpec.describe Fastlane::Actions::DevnotesWritePlayChangelogsAction do
  let(:api_url) { "https://api.devnotes.test" }
  let(:api_key) { "test-key-abc" }
  let(:owner) { "byteforge" }
  let(:project_slug) { "podcast-guru-android" }
  let(:project_id) { "11111111-1111-4111-8111-111111111111" }
  let(:release_id) { 4242 }
  let(:job_id) { "22222222-2222-4222-8222-222222222222" }
  let(:version_code) { "123456" }
  let(:format_slug) { "play-store-changelog" }

  let(:project_response) do
    {
      "id" => project_id,
      "slug" => project_slug,
      "created_by_username" => owner,
      "name" => "Podcast Guru Android",
    }
  end

  let(:submit_response) { { "job_id" => job_id } }
  let(:completed_job) do
    {
      "id" => job_id,
      "status" => "completed",
      "result_data" => { "release_id" => release_id },
    }
  end

  def format_response(locale, content, translated: false, attempts: nil)
    {
      "content" => content,
      "format_slug" => format_slug,
      "mime_type" => "text/plain",
      "model" => "anthropic/claude-sonnet-4-6",
      "prompt_hash" => "deadbeef" * 8,
      "generated_at" => 1_719_000_000,
      "locale" => locale,
      "translated" => translated,
      "max_char_length" => 480,
      "translation_attempts" => attempts,
    }
  end

  # ---- harness: tmp project tree + stubbed lane context -----------------

  # Dir.mktmpdir's block form handles cleanup — but `around` can't host
  # rspec-mocks `allow()` calls, so we split: `around` owns the tmpdir
  # lifecycle, `before` does the stubs (which require the per-test
  # rspec-mocks lifecycle).
  around do |example|
    Dir.mktmpdir("devnotes-play-spec-") do |tmp|
      @project_root = tmp
      FileUtils.mkdir_p(File.join(tmp, "app/src/main/res/values"))    # default, will be skipped
      FileUtils.mkdir_p(File.join(tmp, "app/src/main/res/values-ru"))
      FileUtils.mkdir_p(File.join(tmp, "app/src/main/res/values-de"))
      # Marker files — the action doesn't read these; having them
      # mirrors the real Android layout (strings.xml is the canonical
      # shipping-languages declaration).
      File.write(File.join(tmp, "app/src/main/res/values/strings.xml"), "<resources/>")
      File.write(File.join(tmp, "app/src/main/res/values-ru/strings.xml"), "<resources/>")
      File.write(File.join(tmp, "app/src/main/res/values-de/strings.xml"), "<resources/>")
      example.run
    end
  end

  before do
    # Stub the mixin's project_root so the action writes inside the
    # tmpdir instead of the real CWD. (FastlaneCore::FastlaneFolder
    # isn't reliably defined in plain RSpec runs and would otherwise
    # fall back to Dir.pwd.)
    allow(Fastlane::Helper::DevnotesActionMixin)
      .to receive(:project_root)
      .and_return(@project_root)

    # Suppress release_name auto-resolve (no git history in tmpdir).
    allow(Fastlane::Helper::DevnotesActionMixin)
      .to receive(:resolve_release_name).and_return("v9.9.9")

    # Clean lane_context per spec so SharedValues assertions don't leak.
    Fastlane::Actions.lane_context.clear
  end

  def stub_happy_path(locales)
    stub_request(:get, "#{api_url}/api/projects/#{owner}/#{project_slug}")
      .with(headers: { "Authorization" => "Bearer #{api_key}" })
      .to_return(status: 200, body: project_response.to_json,
                 headers: { "Content-Type" => "application/json" })

    stub_request(:post, "#{api_url}/api/projects/#{owner}/#{project_slug}/generate-release-notes")
      .to_return(status: 200, body: submit_response.to_json,
                 headers: { "Content-Type" => "application/json" })

    stub_request(:get, "#{api_url}/api/jobs/#{job_id}")
      .to_return(status: 200, body: completed_job.to_json,
                 headers: { "Content-Type" => "application/json" })

    locales.each do |(bcp47, content, translated, attempts)|
      url = "#{api_url}/api/projects/#{owner}/#{project_slug}/releases/#{release_id}/formats/#{format_slug}"
      url += "?locale=#{bcp47}"
      stub_request(:get, url).to_return(
        status: 200,
        body: format_response(bcp47, content, translated: translated, attempts: attempts).to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end
  end

  def call_action(opts)
    described_class.run(
      FastlaneCore::Configuration.create(described_class.available_options, opts)
    )
  end

  # ---- the happy paths ---------------------------------------------------

  describe "auto-discovery mode" do
    it "skips non-locale Android qualifiers (values-night, values-v21, values-car) and writes only locale files" do
      # Add non-locale qualifiers to the tmp tree — these are legitimate
      # Android resource directories that must NOT crash the lane.
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-night"))
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-v21"))
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-car"))

      stub_happy_path([
        ["ru-RU", "ru body", true, 1],
        ["de-DE", "de body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
      )

      # ru-RU and de-DE write; values-night / values-v21 / values-car are skipped.
      expect(result[:locales]).to contain_exactly("ru-RU", "de-DE")
      skipped_quals = result[:skipped].map { |s| s[:qualifier] }
      expect(skipped_quals).to include("values-night", "values-v21", "values-car", "values")
    end

    it "discovers values-{ru,de}, skips values/, writes two changelog files" do
      stub_happy_path([
        ["ru-RU", "ru-changelog 🚀", true, 1],
        ["de-DE", "de-changelog 🚀", true, 2],
      ])

      result = call_action(
        api_url: api_url,
        api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
      )

      expect(result[:locales]).to contain_exactly("ru-RU", "de-DE")
      expect(result[:skipped].map { |s| s[:qualifier] }).to include("values")

      ru_path = File.join(@project_root, "fastlane/metadata/android/ru-RU/changelogs/#{version_code}.txt")
      de_path = File.join(@project_root, "fastlane/metadata/android/de-DE/changelogs/#{version_code}.txt")
      expect(File.exist?(ru_path)).to be(true)
      expect(File.exist?(de_path)).to be(true)
      expect(File.read(ru_path)).to eq("ru-changelog 🚀")
      expect(File.read(de_path)).to eq("de-changelog 🚀")
    end

    it "stores the result in SharedValues::DEVNOTES_PLAY_CHANGELOG_PATHS" do
      stub_happy_path([
        ["ru-RU", "x", true, 1],
        ["de-DE", "y", true, 1],
      ])

      call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
      )

      shared = Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::DEVNOTES_PLAY_CHANGELOG_PATHS]
      expect(shared[:locales]).to contain_exactly("ru-RU", "de-DE")
      expect(shared[:paths].length).to eq(2)
    end
  end

  describe "qualifier_overrides[''] — base values/ dir (v0.8.1)" do
    it "includes the default-language listing when '' is declared" do
      # Every real Android project has values/ (the default qualifier).
      # In v0.8.0 that dir was ALWAYS skipped with a warning, so
      # auto-discovery dropped the primary Play Store listing (usually
      # en-US). v0.8.1 lets the operator declare the mapping.
      stub_happy_path([
        ["en-US", "en body", false, nil],
        ["ru-RU", "ru body", true, 1],
        ["de-DE", "de body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        qualifier_overrides: { "" => "en-US" },
      )

      expect(result[:locales]).to contain_exactly("en-US", "ru-RU", "de-DE")
      en_path = File.join(@project_root, "fastlane/metadata/android/en-US/changelogs/#{version_code}.txt")
      expect(File.exist?(en_path)).to be(true)
      expect(File.read(en_path)).to eq("en body")
    end

    it "still skips bare values/ when '' is NOT declared (backward-compat)" do
      # v0.8.0 behavior stays the default — no silent en-US inference.
      stub_happy_path([
        ["ru-RU", "ru body", true, 1],
        ["de-DE", "de body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
      )

      expect(result[:locales]).to contain_exactly("ru-RU", "de-DE")
      expect(result[:skipped].map { |s| s[:qualifier] }).to include("values")
    end
  end

  describe "qualifier_overrides — auto-discovery rescues ambiguous / unmapped" do
    it "rescues bare 'pt' via qualifier_overrides → auto-discovery works" do
      # Add values-pt to the tree — the ambiguous case that would hard-fail
      # in v0.6.0. With qualifier_overrides declaring pt → pt-PT, the
      # ambiguity guard is bypassed and auto-discovery completes.
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-pt"))

      stub_happy_path([
        ["ru-RU", "ru body", true, 1],
        ["de-DE", "de body", true, 1],
        ["pt-PT", "pt body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        qualifier_overrides: { "pt" => "pt-PT" },
      )

      expect(result[:locales]).to contain_exactly("ru-RU", "de-DE", "pt-PT")
      pt_path = File.join(@project_root, "fastlane/metadata/android/pt-PT/changelogs/#{version_code}.txt")
      expect(File.exist?(pt_path)).to be(true)
    end

    it "writes BOTH values-pt AND values-pt-rBR when both exist (region-dedup is gone)" do
      # v0.6.0 silently dropped values-pt when values-pt-rBR existed. v0.6.1
      # writes both — apps with distinct locale listings depend on this.
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-pt"))
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-pt-rBR"))

      stub_happy_path([
        ["ru-RU", "ru", true, 1],
        ["de-DE", "de", true, 1],
        ["pt-PT", "eu-pt", true, 1],
        ["pt-BR", "br-pt", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        qualifier_overrides: { "pt" => "pt-PT" },
      )

      # Both pt-PT AND pt-BR written.
      expect(result[:locales]).to include("pt-PT", "pt-BR")
    end
  end

  describe "strict: true — silent skip becomes hard-fail" do
    it "hard-fails on an unmapped bare-language qualifier (values-fa)" do
      # v0.6.0 silently skipped values-fa. Under strict, it must abort.
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-fa"))

      stub_happy_path([])

      expect do
        call_action(
          api_url: api_url, api_key: api_key,
          project_slug: "#{owner}/#{project_slug}",
          version_code: version_code,
          strict: true,
        )
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /values-fa.*strict/mi)
    end

    it "still skips MALFORMED qualifiers (values-night) even under strict" do
      # values-night is genuinely not a locale — strict shouldn't turn
      # ANDROID resource qualifiers into build breakers.
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-night"))

      stub_happy_path([
        ["ru-RU", "ru", true, 1],
        ["de-DE", "de", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        strict: true,
      )

      expect(result[:locales]).to contain_exactly("ru-RU", "de-DE")
      expect(result[:skipped].map { |s| s[:qualifier] }).to include("values-night")
    end

    it "qualifier_overrides + strict together — override wins over strict" do
      # If the operator explicitly declared a mapping, strict shouldn't
      # trip because there's no unresolved qualifier.
      FileUtils.mkdir_p(File.join(@project_root, "app/src/main/res/values-fa"))

      stub_happy_path([
        ["ru-RU", "ru", true, 1],
        ["de-DE", "de", true, 1],
        ["fa", "fa body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        qualifier_overrides: { "fa" => "fa" },
        strict: true,
      )

      expect(result[:locales]).to include("fa")
    end
  end

  describe "explicit locales: mode" do
    it "honors the explicit list and skips res scanning" do
      stub_happy_path([
        ["en-US", "en body", false, nil],
        ["ru-RU", "ru body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        locales: ["en-US", "ru-RU"],
      )

      expect(result[:locales]).to eq(["en-US", "ru-RU"])
      en_path = File.join(@project_root, "fastlane/metadata/android/en-US/changelogs/#{version_code}.txt")
      expect(File.read(en_path)).to eq("en body")
    end

    it "applies locale_overrides" do
      stub_happy_path([
        ["es-MX", "es body", true, 1],
      ])

      result = call_action(
        api_url: api_url, api_key: api_key,
        project_slug: "#{owner}/#{project_slug}",
        version_code: version_code,
        locales: ["es-MX"],
        locale_overrides: { "es-419" => "es-MX" },  # undo the default es-MX → es-419 collapse
      )

      expect(result[:locales]).to eq(["es-MX"])
      es_path = File.join(@project_root, "fastlane/metadata/android/es-MX/changelogs/#{version_code}.txt")
      expect(File.exist?(es_path)).to be(true)
    end
  end

  # ---- failure modes -----------------------------------------------------

  describe "version_code validation" do
    it "fails loud on non-digit version_code" do
      stub_happy_path([])  # nothing should be fetched

      expect do
        call_action(
          api_url: api_url, api_key: api_key,
          project_slug: "#{owner}/#{project_slug}",
          version_code: "1.0-rc1",
          locales: ["en-US"],
        )
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /version_code/)
    end
  end

  describe "TranslationFitError" do
    it "wraps the typed 422 in a UI.user_error! that names the locale and limits" do
      stub_request(:get, "#{api_url}/api/projects/#{owner}/#{project_slug}")
        .to_return(status: 200, body: project_response.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{api_url}/api/projects/#{owner}/#{project_slug}/generate-release-notes")
        .to_return(status: 200, body: submit_response.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{api_url}/api/jobs/#{job_id}")
        .to_return(status: 200, body: completed_job.to_json,
                   headers: { "Content-Type" => "application/json" })

      stub_request(:get, "#{api_url}/api/projects/#{owner}/#{project_slug}/releases/#{release_id}/formats/#{format_slug}?locale=ru-RU")
        .to_return(
          status: 422,
          body: {
            "code" => 422,
            "status" => "Unprocessable Entity",
            "message" => "translation does not fit",
            "attempts" => 3,
            "best_length" => 502,
            "max_char_length" => 480,
            "locale" => "ru-RU",
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect do
        call_action(
          api_url: api_url, api_key: api_key,
          project_slug: "#{owner}/#{project_slug}",
          version_code: version_code,
          locales: ["ru-RU"],
        )
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /max_char_length=480.*best attempt was 502/m)
    end
  end
end
