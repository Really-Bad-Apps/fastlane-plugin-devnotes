require "spec_helper"

RSpec.describe Fastlane::Helper::DevnotesLocaleMap do
  describe ".qualifier_to_bcp47" do
    context "bare-language safe defaults" do
      it "maps 'ru' to 'ru-RU'" do
        expect(described_class.qualifier_to_bcp47("ru")).to eq("ru-RU")
      end

      it "maps 'de' to 'de-DE'" do
        expect(described_class.qualifier_to_bcp47("de")).to eq("de-DE")
      end

      it "maps 'ko' to 'ko-KR'" do
        expect(described_class.qualifier_to_bcp47("ko")).to eq("ko-KR")
      end

      it "maps 'en' to 'en-US'" do
        expect(described_class.qualifier_to_bcp47("en")).to eq("en-US")
      end

      it "passes 'ar' through region-less (Play Store accepts it)" do
        expect(described_class.qualifier_to_bcp47("ar")).to eq("ar")
      end
    end

    context "region-qualified <lang>-r<REGION>" do
      it "maps 'pt-rBR' to 'pt-BR'" do
        expect(described_class.qualifier_to_bcp47("pt-rBR")).to eq("pt-BR")
      end

      it "maps 'zh-rTW' to 'zh-TW'" do
        expect(described_class.qualifier_to_bcp47("zh-rTW")).to eq("zh-TW")
      end

      it "maps 'es-rMX' to 'es-MX' (region overrides the bare-es ambiguity)" do
        expect(described_class.qualifier_to_bcp47("es-rMX")).to eq("es-MX")
      end

      it "translates the legacy ISO 'iw-rIL' alias to 'he-IL'" do
        expect(described_class.qualifier_to_bcp47("iw-rIL")).to eq("he-IL")
      end
    end

    context "newer b+ form" do
      it "maps 'b+zh+Hans+CN' to 'zh-Hans-CN'" do
        expect(described_class.qualifier_to_bcp47("b+zh+Hans+CN")).to eq("zh-Hans-CN")
      end

      it "maps 'b+sr+Latn' to 'sr-Latn'" do
        expect(described_class.qualifier_to_bcp47("b+sr+Latn")).to eq("sr-Latn")
      end

      it "raises on a malformed b+ qualifier" do
        expect { described_class.qualifier_to_bcp47("b+") }
          .to raise_error(described_class::UnmappableQualifierError)
        expect { described_class.qualifier_to_bcp47("b++zh") }
          .to raise_error(described_class::UnmappableQualifierError)
      end
    end

    context "legacy ISO 639 aliases" do
      it "maps bare 'iw' to 'he' (then through to 'he')" do
        # iw → he. Hebrew is in BARE_LANGUAGE_DEFAULTS as region-less 'he'.
        expect(described_class.qualifier_to_bcp47("iw")).to eq("he")
      end

      it "maps bare 'in' to 'id'" do
        expect(described_class.qualifier_to_bcp47("in")).to eq("id")
      end
    end

    context "ambiguous bare-language hard-fail" do
      %w[pt zh es].each do |qualifier|
        it "raises UnmappableQualifierError on bare '#{qualifier}'" do
          expect { described_class.qualifier_to_bcp47(qualifier) }
            .to raise_error(described_class::UnmappableQualifierError, /ambiguous/i)
        end

        it "tags the ambiguous case with :reason => :ambiguous" do
          described_class.qualifier_to_bcp47(qualifier)
        rescue described_class::UnmappableQualifierError => e
          expect(e.reason).to eq(:ambiguous)
          expect(e.message).to include("raw-#{qualifier}")
        end
      end
    end

    context "unknown bare-language qualifier (could be a non-locale Android qualifier)" do
      it "raises with reason :unknown — caller may choose to skip or fail" do
        described_class.qualifier_to_bcp47("xx")
      rescue described_class::UnmappableQualifierError => e
        expect(e.reason).to eq(:unknown)
      end

      it "tags 'raw-car' (Android car UI mode) as :unknown, NOT :ambiguous" do
        # Critical for the action's auto-discovery: `raw-car/` is a
        # legitimate non-locale Android qualifier and must be skippable
        # without halting the build.
        described_class.qualifier_to_bcp47("car")
      rescue described_class::UnmappableQualifierError => e
        expect(e.reason).to eq(:unknown)
      end
    end

    context "qualifier_overrides (operator's Rosetta table)" do
      it "rescues an AMBIGUOUS bare-language qualifier (pt → pt-PT)" do
        # Without overrides, bare "pt" hard-fails. With an override
        # declared, the override wins BEFORE the ambiguity guard runs.
        expect(described_class.qualifier_to_bcp47("pt", overrides: { "pt" => "pt-PT" }))
          .to eq("pt-PT")
      end

      it "rescues an UNMAPPED bare-language qualifier (fa → fa)" do
        # fa isn't in BARE_LANGUAGE_DEFAULTS; without overrides, it
        # raises :unknown. With an override, the mapping is used.
        expect(described_class.qualifier_to_bcp47("fa", overrides: { "fa" => "fa" }))
          .to eq("fa")
      end

      it "overrides can override a normally-mapped bare-language (en → en-GB)" do
        # Built-in default is en → en-US; override wins.
        expect(described_class.qualifier_to_bcp47("en", overrides: { "en" => "en-GB" }))
          .to eq("en-GB")
      end

      it "overrides work on a region-qualified qualifier ('es-rMX' → 'es-419')" do
        # Some ops want raw-es-rMX to collapse to es-419 immediately at
        # the qualifier layer (skipping the built-in region-qualified
        # path). Overrides run first, so this works.
        expect(described_class.qualifier_to_bcp47("es-rMX", overrides: { "es-rMX" => "es-419" }))
          .to eq("es-419")
      end

      it "no override matches → falls through to built-in rules" do
        # If overrides doesn't contain the qualifier, downstream rules
        # run normally. Guarantees the escape hatch doesn't accidentally
        # shadow the built-in defaults for unrelated qualifiers.
        expect(described_class.qualifier_to_bcp47("ru", overrides: { "pt" => "pt-PT" }))
          .to eq("ru-RU")
      end

      it "nil overrides is safe" do
        expect(described_class.qualifier_to_bcp47("ru", overrides: nil)).to eq("ru-RU")
      end

      it "empty-string override value falls through to built-in rules" do
        # Defensive: an operator typo like `{ "ru" => "" }` should NOT
        # return "" and silently ship a blank locale downstream. Fall
        # through instead so the built-in default takes over.
        expect(described_class.qualifier_to_bcp47("ru", overrides: { "ru" => "" }))
          .to eq("ru-RU")
      end

      it "whitespace-only override value also falls through" do
        expect(described_class.qualifier_to_bcp47("ru", overrides: { "ru" => "   " }))
          .to eq("ru-RU")
      end

      it "empty-string qualifier + '' override → returns the mapped locale (v0.8.1)" do
        # The v0.8.1 fix: the bare `values/` dir is representable in
        # qualifier_overrides via the empty-string key. Without this
        # path, auto-discovery drops the default-language listing —
        # for most localized apps that means en-US silently vanishes.
        expect(described_class.qualifier_to_bcp47("", overrides: { "" => "en-US" }))
          .to eq("en-US")
      end

      it "empty-string qualifier + NO override → raises UnmappableQualifierError (backward-compat)" do
        # Same as v0.8.0 behavior when the operator hasn't declared "".
        # The action's caller catches this and either skips (default)
        # or hard-fails (strict: true).
        expect { described_class.qualifier_to_bcp47("", overrides: {}) }
          .to raise_error(described_class::UnmappableQualifierError, /empty/)
      end

      it "empty-string qualifier + nil overrides → raises (backward-compat)" do
        expect { described_class.qualifier_to_bcp47("", overrides: nil) }
          .to raise_error(described_class::UnmappableQualifierError)
      end
    end

    context "malformed qualifier (longer than 3 chars, not a locale shape)" do
      it "raises :malformed for 'night' (Android UI mode qualifier)" do
        described_class.qualifier_to_bcp47("night")
      rescue described_class::UnmappableQualifierError => e
        expect(e.reason).to eq(:malformed)
      end

      it "raises :malformed for 'mcc310-mnc004' (Android MCC qualifier)" do
        described_class.qualifier_to_bcp47("mcc310-mnc004")
      rescue described_class::UnmappableQualifierError => e
        expect(e.reason).to eq(:malformed)
      end

      it "raises :malformed for a wholly garbage shape" do
        described_class.qualifier_to_bcp47("not-a-qualifier-shape")
      rescue described_class::UnmappableQualifierError => e
        expect(e.reason).to eq(:malformed)
      end
    end

    context "default qualifier (bare raw/)" do
      it "raises DefaultQualifierError on nil" do
        expect { described_class.qualifier_to_bcp47(nil) }
          .to raise_error(described_class::DefaultQualifierError)
      end
    end

    context "garbage input" do
      it "raises on an empty string" do
        expect { described_class.qualifier_to_bcp47("") }
          .to raise_error(described_class::UnmappableQualifierError, /empty/)
      end

      it "raises on a totally unrecognized shape" do
        expect { described_class.qualifier_to_bcp47("not-a-qualifier-shape") }
          .to raise_error(described_class::UnmappableQualifierError)
      end
    end
  end

  describe ".bcp47_to_play_store" do
    let(:silent_warn) { ->(_msg) {} }

    context "hard-coded quirks" do
      it "collapses es-MX to es-419" do
        expect(described_class.bcp47_to_play_store("es-MX", warn: silent_warn))
          .to eq("es-419")
      end

      it "collapses es-AR to es-419" do
        expect(described_class.bcp47_to_play_store("es-AR", warn: silent_warn))
          .to eq("es-419")
      end

      it "rewrites zh-Hans to zh-CN" do
        expect(described_class.bcp47_to_play_store("zh-Hans", warn: silent_warn))
          .to eq("zh-CN")
      end

      it "rewrites zh-Hant to zh-TW" do
        expect(described_class.bcp47_to_play_store("zh-Hant", warn: silent_warn))
          .to eq("zh-TW")
      end

      it "rewrites bare 'en' to 'en-US'" do
        expect(described_class.bcp47_to_play_store("en", warn: silent_warn))
          .to eq("en-US")
      end
    end

    context "passthrough" do
      %w[ru-RU pt-BR de-DE fr-FR en-US en-GB ja-JP ko-KR].each do |code|
        it "passes #{code} through unchanged" do
          expect(described_class.bcp47_to_play_store(code, warn: silent_warn)).to eq(code)
        end
      end
    end

    context "overrides take last-wins precedence" do
      it "applies an override to a passthrough locale" do
        expect(
          described_class.bcp47_to_play_store(
            "ru-RU",
            overrides: { "ru-RU" => "ru" },
            warn: silent_warn
          )
        ).to eq("ru")
      end

      it "applies an override AFTER the quirk pass (operator can re-rewrite es-419)" do
        # es-MX → quirks → es-419. Override on es-419 wins; override on es-MX
        # also wins because we check both keys.
        expect(
          described_class.bcp47_to_play_store(
            "es-MX",
            overrides: { "es-419" => "es-MX" },
            warn: silent_warn
          )
        ).to eq("es-MX")
      end

      it "tolerates nil overrides hash" do
        expect(
          described_class.bcp47_to_play_store("ru-RU", overrides: nil, warn: silent_warn)
        ).to eq("ru-RU")
      end
    end

    context "warn on miss" do
      it "emits a warning when the final code is not in the allowlist" do
        captured = []
        described_class.bcp47_to_play_store(
          "xx-YY",
          warn: ->(msg) { captured << msg }
        )
        expect(captured).not_to be_empty
        expect(captured.first).to match(/not in the known Play Store/)
      end

      it "does NOT warn when the final code IS in the allowlist" do
        captured = []
        described_class.bcp47_to_play_store(
          "ru-RU",
          warn: ->(msg) { captured << msg }
        )
        expect(captured).to be_empty
      end
    end

    context "input guards" do
      it "raises ArgumentError on an empty string" do
        expect { described_class.bcp47_to_play_store("", warn: silent_warn) }
          .to raise_error(ArgumentError)
      end

      it "raises ArgumentError on nil" do
        expect { described_class.bcp47_to_play_store(nil, warn: silent_warn) }
          .to raise_error(ArgumentError)
      end
    end
  end
end
