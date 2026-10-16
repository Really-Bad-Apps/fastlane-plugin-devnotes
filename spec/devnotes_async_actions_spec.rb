require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Actions consuming async format jobs" do
  around do |example|
    Dir.mktmpdir("devnotes-async-") do |dir|
      @root = dir
      example.run
    end
  end

  before do
    allow(Fastlane::Helper::DevnotesActionMixin).to receive(:project_root).and_return(@root)
    Fastlane::Actions.lane_context.clear
    stub_request(:get, "https://devnotes.test/api/projects/jason/app")
      .to_return(body: { id: "project", created_by_username: "jason", slug: "app" }.to_json)
    stub_request(:post, "https://devnotes.test/api/projects/jason/app/generate-release-notes")
      .to_return(body: { job_id: 55 }.to_json)
    stub_request(:get, "https://devnotes.test/api/jobs/55")
      .to_return(body: { id: 55, status: "completed", result_data: { release_id: 42 } }.to_json)
  end

  [Fastlane::Actions::DevnotesFetchInlineAction, Fastlane::Actions::DevnotesWritePlayChangelogsAction].each do |action|
    [false, true].each do |failed|
      it "#{action.name} #{failed ? 'preserves the existing file on failure' : 'writes the completed format result'}" do
        inline = action == Fastlane::Actions::DevnotesFetchInlineAction
        path = if inline
          File.join(@root, "app/src/main/res/raw-de/rnotes.txt")
        else
          File.join(@root, "fastlane/metadata/android/de-DE/changelogs/1043.txt")
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "existing content")
        options = { api_url: "https://devnotes.test", api_key: "secret", project_slug: "jason/app",
                    release_name: "2.3.4-beta1", format_slug: "mobile-html" }
        options.merge!(inline ? { locale: "de-DE", output_path: path } : { locales: ["de-DE"], version_code: "1043" })
        id = "12345678-1234-1234-1234-123456789abc"
        stub_request(:get, "https://devnotes.test/api/projects/jason/app/releases/42/formats/mobile-html?locale=de-DE")
          .to_return(status: 202, body: { job_id: id, status: "pending" }.to_json)
        body = if failed
          { status: "failed", error: { code: 503, message: "Provider failed" } }
        else
          { status: "completed", result: { content: "<p>Neu 🎉</p>", mime_type: "text/html" } }
        end
        stub_request(:get, "https://devnotes.test/api/format-jobs/#{id}").to_return(body: body.to_json)
        run = -> { action.run(FastlaneCore::Configuration.create(action.available_options, options)) }
        if failed
          expect(&run).to raise_error(FastlaneCore::Interface::FastlaneError, /Provider failed/)
          expect(File.read(path)).to eq("existing content")
        else
          run.call
          expect(File.read(path)).to eq("<p>Neu 🎉</p>")
        end
      end
    end
  end
end
