lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fastlane/plugin/devnotes/version"

Gem::Specification.new do |spec|
  spec.name          = "fastlane-plugin-devnotes"
  spec.version       = Fastlane::Devnotes::VERSION
  spec.author        = "Jason Byteforge"
  spec.email         = "jason@reallybadapps.com"

  spec.summary       = "Generate and fetch DevNotes mobile release notes during a Fastlane build."
  spec.description   = "Submits a release-notes generation job to the DevNotes API, polls until complete, " \
                       "and writes the mobile HTML variant to a path inside the Android source tree so the " \
                       "app can bundle it as a resource."
  spec.homepage      = "https://github.com/Really-Bad-Apps/fastlane-plugin-devnotes"
  spec.license       = "Nonstandard"

  spec.files         = Dir["lib/**/*"] + %w[README.md LICENSE]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.6"

  # No runtime deps. The plugin uses Ruby stdlib (net/http, json, uri, openssl)
  # so it stays light inside consumer Pluginfiles.

  spec.add_development_dependency("bundler")
  spec.add_development_dependency("rake")
  spec.add_development_dependency("rspec")
  spec.add_development_dependency("webmock")
  spec.add_development_dependency("fastlane", ">= 2.200.0")
end
