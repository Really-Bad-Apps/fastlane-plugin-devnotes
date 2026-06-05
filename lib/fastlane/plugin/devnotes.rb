require "fastlane/plugin/devnotes/version"

module Fastlane
  module Devnotes
    def self.all_classes
      Dir[File.expand_path("**/{actions,helper}/*.rb", File.dirname(__FILE__))]
    end
  end
end

Fastlane::Devnotes.all_classes.each do |current|
  require(current)
end
