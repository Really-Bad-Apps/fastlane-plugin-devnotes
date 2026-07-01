require "set"

module Fastlane
  module Helper
    # Pure mapping functions: Android resource qualifier ↔ BCP 47 ↔ Google
    # Play Store metadata locale. No fastlane runtime, no UI calls — every
    # function is stdlib-only so the locale-map spec runs without a
    # Fastfile / lane context.
    module DevnotesLocaleMap
      # Sentinel raised when the caller passes nil (i.e. bare `raw/`). The
      # write-play-changelogs action catches this and emits a UI.important
      # line — `raw/` is the Android default qualifier and guessing en-US
      # is wrong when the app's default language isn't English.
      class DefaultQualifierError < StandardError; end

      # Raised when a qualifier is ambiguous (`pt`, `zh`, `es`) or unknown.
      # Caller dispatches on `:reason`:
      #   :ambiguous  — bare-language locale (pt/zh/es); operator must
      #                 specify a region. Hard-fail.
      #   :unknown    — could be a non-locale Android qualifier
      #                 (`raw-night/`, `raw-car/`, `raw-mcc310/`). Skip
      #                 with a warning.
      #   :malformed  — doesn't match any locale shape we know
      #                 (`raw-not-a-real-qual/`). Skip with a warning.
      class UnmappableQualifierError < StandardError
        attr_reader :qualifier, :reason

        def initialize(qualifier, message, reason: :unknown)
          super(message)
          @qualifier = qualifier
          @reason = reason
        end
      end

      # Bare-language → BCP 47 defaults for cases where the regional choice
      # isn't genuinely ambiguous (one dominant region). For the ambiguous
      # cases (pt, zh, es) we hard-fail and ask the operator to use the
      # qualifier's full form (raw-pt-rBR) or pass locales: explicitly.
      BARE_LANGUAGE_DEFAULTS = {
        "en" => "en-US",
        "ru" => "ru-RU",
        "ko" => "ko-KR",
        "ja" => "ja-JP",
        "de" => "de-DE",
        "fr" => "fr-FR",
        "it" => "it-IT",
        "nl" => "nl-NL",
        "pl" => "pl-PL",
        "tr" => "tr-TR",
        "th" => "th-TH",
        "vi" => "vi-VN",
        "hi" => "hi-IN",
        # ar / he / id deliberately stay region-less in BCP 47 — Play Store
        # accepts the bare two-letter codes for these.
        "ar" => "ar",
        "he" => "he",
        "id" => "id",
      }.freeze

      AMBIGUOUS_BARE_LANGUAGES = {
        "pt" => "Brazilian (pt-BR) vs European (pt-PT)",
        "zh" => "Simplified Mainland (zh-CN), Traditional Taiwan (zh-TW), or Hong Kong (zh-HK)",
        "es" => "European (es-ES), Latin America (es-419), or a specific country (es-MX, es-AR, …)",
      }.freeze

      # Android historically uses pre-1989 ISO 639 codes that diverge from
      # BCP 47. Map them on the way in so operators don't have to know.
      LEGACY_ISO_ALIASES = {
        "iw" => "he",  # Hebrew
        "in" => "id",  # Indonesian
        "ji" => "yi",  # Yiddish
      }.freeze

      # BCP 47 codes that Play Store rewrites to a regional grouping. The
      # operator's `locale_overrides:` arg takes precedence over this table.
      PLAY_STORE_QUIRKS = {
        # Spanish dialects without a specific Play Store listing collapse
        # into the Latin America locale (es-419).
        "es-MX" => "es-419",
        "es-AR" => "es-419",
        "es-CO" => "es-419",
        "es-CL" => "es-419",
        "es-PE" => "es-419",
        # BCP 47 script tags → Play Store regional codes.
        "zh-Hans" => "zh-CN",
        "zh-Hant" => "zh-TW",
        # Bare "en" → US default.
        "en" => "en-US",
      }.freeze

      # Conservative allowlist used for the warn-on-miss check at the
      # bottom of bcp47_to_play_store. Keep this small — it's a smoke
      # gate, not a closed enum (Google adds locales periodically).
      KNOWN_PLAY_STORE_LOCALES = Set.new(%w[
        af am ar-AE ar-BH ar-DZ ar-EG ar-IQ ar-JO ar-KW ar-LB ar-LY ar-MA
        ar-OM ar-QA ar-SA ar-TN ar-YE az-AZ be bg bn-BD ca cs-CZ da-DK
        de-AT de-CH de-DE el-GR en-AU en-CA en-GB en-IE en-IN en-SG en-US
        en-XA en-ZA es-419 es-AR es-BO es-CL es-CO es-CR es-DO es-EC es-ES
        es-GT es-HN es-MX es-NI es-PA es-PE es-PR es-PY es-SV es-US es-UY
        es-VE et fa fa-AE fa-AF fa-IR fi-FI fil fr-CA fr-CH fr-FR gl-ES
        he-IL hi-IN hr hu-HU hy-AM id is-IS it-IT iw-IL ja-JP ka-GE kk
        km-KH kn-IN ko-KR ky-KG lo-LA lt lv mk-MK ml-IN mn-MN mr-IN ms
        ms-MY my-MM nb-NO ne-NP nl-NL pl-PL pt-BR pt-PT rm ro ru-RU si-LK
        sk sl sr sv-SE sw ta-IN te-IN th tr-TR uk uz-UZ vi-VN zh-CN zh-HK
        zh-TW zu
      ]).freeze

      # Android resource qualifier (the part after `raw-`) → BCP 47.
      # Caller is responsible for stripping the `raw-` / `raw` prefix.
      #
      # Argument shapes handled:
      #   nil            → DefaultQualifierError (the bare `raw/` case)
      #   "ru"           → bare language, looked up in BARE_LANGUAGE_DEFAULTS
      #   "pt-rBR"       → split on -r, return "pt-BR"
      #   "zh-rTW"       → "zh-TW"
      #   "b+zh+Hans+CN" → BCP 47 form, joined with "-" → "zh-Hans-CN"
      #
      # `overrides` (default `{}`) is the operator's Rosetta table: an
      # Android-qualifier-string → BCP-47-string map that gets checked
      # FIRST, before any of the built-in rules. This is the escape
      # hatch for the ambiguous cases (pt/zh/es — where the built-in
      # rules hard-fail) and for unmapped bare-languages (fa, hy, etc.)
      # that would otherwise silently skip in the action's discovery
      # loop. Passing `overrides: { "pt" => "pt-PT", "es" => "es-419",
      # "fa" => "fa" }` makes auto-discovery Just Work for those apps.
      def self.qualifier_to_bcp47(qualifier, overrides: {})
        raise DefaultQualifierError, "bare raw/ qualifier" if qualifier.nil?

        normalized = qualifier.to_s.strip

        # Operator's Rosetta table wins over every built-in rule. This
        # is what makes the ambiguous (pt/zh/es) hard-fail path
        # configurable — the AMBIGUOUS raise below is unreachable when
        # the operator has already declared a decision for that
        # qualifier. Same for unmapped bare-languages (fa, hy, …).
        # AND for the empty-string case — an entry `{ "" => "en-US" }`
        # rescues the bare `values/` (default qualifier) dir that
        # build_pairs_from_res_path would otherwise skip. Empty /
        # whitespace-only override values fall through so a typo like
        # `{ "pt" => "" }` doesn't silently ship a blank locale — the
        # downstream ArgumentError isn't caught by the action's rescue
        # chain, better to just ignore the entry and surface the
        # fall-through error path.
        if overrides
          override_value = overrides[normalized]
          if override_value && !override_value.to_s.strip.empty?
            return override_value.to_s
          end
        end

        # Empty qualifier with no override → raise. Non-empty qualifier
        # can't reach this line (normalized was checked non-empty by the
        # regex-based dispatch below on the qualifier's own content).
        raise UnmappableQualifierError.new(qualifier, "empty qualifier") if normalized.empty?

        # Newer BCP 47 form: b+lang[+script[+region]]
        if normalized.start_with?("b+")
          parts = normalized.sub(/\Ab\+/, "").split("+")
          if parts.empty? || parts.any?(&:empty?)
            raise UnmappableQualifierError.new(
              qualifier,
              "malformed b+ qualifier '#{qualifier}'",
              reason: :malformed
            )
          end
          return parts.join("-")
        end

        # Region-qualified: <lang>-r<REGION>
        if (match = normalized.match(/\A([a-z]{2,3})-r([A-Z]{2})\z/))
          lang = LEGACY_ISO_ALIASES.fetch(match[1], match[1])
          return "#{lang}-#{match[2]}"
        end

        # Bare language: <lang>
        if normalized.match?(/\A[a-z]{2,3}\z/)
          lang = LEGACY_ISO_ALIASES.fetch(normalized, normalized)
          if (hint = AMBIGUOUS_BARE_LANGUAGES[lang])
            # AMBIGUOUS is distinct from UNKNOWN: this IS clearly a locale,
            # operator just didn't specify region. Hard-fail.
            raise UnmappableQualifierError.new(
              qualifier,
              "ambiguous bare-language qualifier 'raw-#{qualifier}' " \
              "(#{hint}). Either rename the directory to use the explicit " \
              "region form (e.g. 'raw-#{lang}-rBR') or pass `locales: [...]` " \
              "explicitly to the action.",
              reason: :ambiguous
            )
          end
          if (mapped = BARE_LANGUAGE_DEFAULTS[lang])
            return mapped
          end
          # Could be a non-locale Android qualifier with 2-3 letters
          # (e.g. `raw-car/` for car UI mode). Caller's choice whether to
          # warn-and-skip or fail.
          raise UnmappableQualifierError.new(
            qualifier,
            "'raw-#{qualifier}' is not a recognized locale qualifier. " \
            "If you meant a language, add to BARE_LANGUAGE_DEFAULTS in " \
            "fastlane-plugin-devnotes or pass `locales: [...]` explicitly; " \
            "if it's a non-locale Android qualifier (e.g. UI mode, density, " \
            "orientation), the auto-discovery path will skip it.",
            reason: :unknown
          )
        end

        raise UnmappableQualifierError.new(
          qualifier,
          "unrecognized Android resource qualifier 'raw-#{qualifier}'. " \
          "Expected '<lang>' or '<lang>-r<REGION>' (e.g. 'ru', 'pt-rBR'). " \
          "Non-locale qualifiers (UI mode, density, orientation, screen-size, " \
          "API version) are not locale codes — auto-discovery will skip them.",
          reason: :malformed
        )
      end

      # BCP 47 → Play Store metadata locale. Applies hard-coded quirks
      # first, then the operator-supplied overrides hash (last wins).
      # Returns the final code; emits a one-time warning when the result
      # isn't in KNOWN_PLAY_STORE_LOCALES so operators learn about typos
      # without a hard failure on Google adding new locales we haven't
      # listed yet.
      #
      # `warn` is injected for testability — pass `->(_msg) {}` in specs
      # that don't care, or a capture lambda to assert on the warning.
      def self.bcp47_to_play_store(bcp47, overrides: {}, warn: method(:_default_warn))
        raise ArgumentError, "bcp47 must be a non-empty string" if bcp47.to_s.strip.empty?

        from_quirks = PLAY_STORE_QUIRKS.fetch(bcp47, bcp47)
        final = (overrides || {})[from_quirks] || (overrides || {})[bcp47] || from_quirks

        unless KNOWN_PLAY_STORE_LOCALES.include?(final)
          warn.call(
            "DevNotes: locale '#{final}' is not in the known Play Store " \
            "locale allowlist. Proceeding anyway — Google occasionally adds " \
            "locales before this plugin lists them. Verify in Play Console " \
            "if the upload fails."
          )
        end

        final
      end

      # Default warning sink — UI.important if we're inside a fastlane run,
      # otherwise stderr (so plain RSpec runs don't break).
      def self._default_warn(message)
        if defined?(FastlaneCore::UI)
          FastlaneCore::UI.important(message)
        else
          Kernel.warn(message)
        end
      end
      private_class_method :_default_warn
    end
  end
end
