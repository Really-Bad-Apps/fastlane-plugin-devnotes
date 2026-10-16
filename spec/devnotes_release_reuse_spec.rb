require "spec_helper"
require "tmpdir"

RSpec.describe "Generate once across all release formats" do
  let(:base) { { api_url: "https://devnotes.test", api_key: "secret", project_slug: "jason/app" } }
  let(:resolve) { Fastlane::Actions::DevnotesResolveReleaseAction }
  let(:inline) { Fastlane::Actions::DevnotesFetchInlineAction }
  let(:play) { Fastlane::Actions::DevnotesWritePlayChangelogsAction }
  let(:generation_url) { "https://devnotes.test/api/projects/jason/app/generate-release-notes" }

  def run_action(action, options)
    action.run(FastlaneCore::Configuration.create(action.available_options, base.merge(options)))
  end

  around do |example|
    Dir.mktmpdir("devnotes-reuse-") do |dir|
      @root = dir
      example.run
    end
  end

  before do
    allow(Fastlane::Helper::DevnotesActionMixin).to receive(:project_root).and_return(@root)
    stub_request(:get, "https://devnotes.test/api/projects/jason/app")
      .to_return(body: { id: "project", created_by_username: "jason", slug: "app" }.to_json)
    stub_request(:post, generation_url).to_return(body: { job_id: 55 }.to_json)
    stub_request(:get, "https://devnotes.test/api/jobs/55")
      .to_return(body: { id: 55, status: "completed", result_data: { release_id: 42 } }.to_json)
  end

  it "submits one generation for 16 inline locales and all Play changelogs" do
    locales = %w[en-US de-DE es-ES fr-FR it-IT pt-BR ru-RU ja-JP ko-KR nl-NL pl-PL tr-TR uk-UA sv-SE da-DK fi-FI]
    release_id = run_action(resolve, release_name: "2.3.4-beta1", from_tag: "2.3.3")
    expect(release_id).to eq(42)
    expect(Fastlane::Helper::DevnotesActionMixin).not_to receive(:resolve_release_name)
    locales.each_with_index do |locale, i|
      %w[mobile-html play-store-changelog].each do |format|
        stub_request(:get, "https://devnotes.test/api/projects/jason/app/releases/42/formats/#{format}?locale=#{locale}")
          .to_return(body: { content: "Notes for #{locale}" }.to_json)
      end
      path = File.join(@root, "#{i}.txt")
      run_action(inline, release_id: release_id, locale: locale, output_path: path)
      expect(File.read(path)).to eq("Notes for #{locale}")
    end
    output = run_action(play, release_id: release_id, locales: locales, version_code: "1043")
    expect(output[:paths].length).to eq(16)
    output[:paths].each { |path| expect(File.read(path)).to start_with("Notes for ") }
    expect(a_request(:post, generation_url)).to have_been_made.once
    expect(a_request(:get, "https://devnotes.test/api/jobs/55")).to have_been_made.once
  end

  it "does not silently reuse a previous build's release" do
    2.times { run_action(resolve, release_name: "2.3.4-beta1") }
    expect(a_request(:post, generation_url)).to have_been_made.twice
  end

  [0, -1].each do |id|
    it "rejects invalid release ID #{id} before HTTP" do
      [inline, play].each do |action|
        options = { release_id: id }
        options[:version_code] = "1043" if action == play
        expect { run_action(action, options) }
          .to raise_error(FastlaneCore::Interface::FastlaneError, /positive integer/)
      end
      expect(a_request(:post, generation_url)).not_to have_been_made
    end
  end

  [:release_name, :from_tag].each do |key|
    it "rejects generation option #{key} alongside a release ID" do
      [inline, play].each do |action|
        options = { release_id: 42, key => "v1" }
        options[:version_code] = "1043" if action == play
        expect { run_action(action, options) }.to raise_error(FastlaneCore::Interface::FastlaneError, /conflict/i)
      end
    end
  end

  [nil, 0, -1, "42"].each do |id|
    it "does not expose invalid completed release ID #{id.inspect}" do
      stub_request(:get, "https://devnotes.test/api/jobs/55")
        .to_return(body: { id: 55, status: "completed", result_data: { release_id: id } }.to_json)
      expect { run_action(resolve, release_name: "v1") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /valid result_data.release_id/)
    end
  end

  [[], "invalid", 42].each do |result|
    it "rejects malformed result_data #{result.inspect} cleanly" do
      stub_request(:get, "https://devnotes.test/api/jobs/55")
        .to_return(body: { id: 55, status: "completed", result_data: result }.to_json)
      expect { run_action(resolve, release_name: "v1") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /valid result_data.release_id/)
    end
  end

  it "polls an async format using the explicit release without regenerating" do
    id = "12345678-1234-1234-1234-123456789abc"
    stub_request(:get, "https://devnotes.test/api/projects/jason/app/releases/42/formats/mobile-html?locale=de-DE")
      .to_return(status: 202, body: { job_id: id, status: "pending" }.to_json)
    stub_request(:get, "https://devnotes.test/api/format-jobs/#{id}")
      .to_return(body: { status: "completed", result: { content: "Neue Notizen" } }.to_json)
    path = File.join(@root, "notes.txt")
    run_action(inline, release_id: 42, locale: "de-DE", output_path: path)
    expect(File.read(path)).to eq("Neue Notizen")
    expect(a_request(:post, generation_url)).not_to have_been_made
  end

  it "stops on generation failure" do
    stub_request(:get, "https://devnotes.test/api/jobs/55")
      .to_return(body: { id: 55, status: "failed", error_message: "Provider failed" }.to_json)
    expect { run_action(resolve, release_name: "v1") }
      .to raise_error(FastlaneCore::Interface::FastlaneError, /Provider failed/)
  end

  it "does not regenerate when an explicit release fetch fails" do
    stub_request(:get, "https://devnotes.test/api/projects/jason/app/releases/42/formats/mobile-html")
      .to_return(status: 404, body: { message: "Release not found" }.to_json)
    expect { run_action(inline, release_id: 42, output_path: File.join(@root, "notes.txt")) }
      .to raise_error(FastlaneCore::Interface::FastlaneError)
    expect(a_request(:post, generation_url)).not_to have_been_made
  end
end
