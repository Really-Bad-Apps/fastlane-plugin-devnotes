require "webmock/rspec"

# Block accidental real HTTP from any spec — the helper has retry / poll
# behavior that would silently hammer the live DevNotes API otherwise.
WebMock.disable_net_connect!(allow_localhost: false)

# Load the full fastlane runtime so action specs can use FastlaneCore
# (Configuration, ConfigItem, Interface::FastlaneError) and the
# lane_context machinery. MUST come before requiring the plugin so the
# auto-required helper/action files can find Fastlane::Action / UI.
require "fastlane"

# Eagerly load the plugin under test so plain unit specs can reference
# the locale-map / mixin / action constants without writing their own
# requires.
require "fastlane/plugin/devnotes"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end
