require "spec_helper"

# Smoke test: requiring the plugin top-level loader pulls in every action
# and helper file via the auto-require glob. A syntax error in any new
# action / helper file would surface here, before any unit spec runs.
RSpec.describe "fastlane-plugin-devnotes load" do
  it "exposes both action classes" do
    expect(Fastlane::Actions::DevnotesFetchInlineAction).to be_a(Class)
    expect(Fastlane::Actions::DevnotesWritePlayChangelogsAction).to be_a(Class)
  end

  it "exposes the shared helper modules" do
    expect(Fastlane::Helper::DevnotesHelper).to be_a(Class)
    expect(Fastlane::Helper::DevnotesActionMixin).to be_a(Module)
    expect(Fastlane::Helper::DevnotesLocaleMap).to be_a(Module)
  end
end
