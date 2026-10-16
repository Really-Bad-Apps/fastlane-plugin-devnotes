require "spec_helper"

RSpec.describe Fastlane::Helper::DevnotesHelper do
  let(:base) { "https://devnotes.test/gateway" }
  let(:client) { described_class.new(api_url: base, api_key: "secret", poll_interval: 1, timeout: 10) }
  let(:job_id) { "12345678-1234-1234-1234-123456789abc" }
  let(:format_url) { "#{base}/api/projects/jason/app/releases/42/formats/mobile-html?locale=de-DE" }
  let(:poll_url) { "#{base}/api/format-jobs/#{job_id}" }
  let(:result) { { "content" => "<p>Neu 🎉</p>", "locale" => "de-DE", "translated" => true } }
  let(:fit_error) do
    { "code" => 422, "message" => "Translation cannot fit max_char_length", "attempts" => 3,
      "best_length" => 510, "max_char_length" => 480, "locale" => "de-DE" }
  end

  def fetch
    client.get_format_output(owner_username: "jason", project_slug: "app", release_id: 42,
                             format_slug: "mobile-html", locale: "de-DE")
  end

  def submit
    stub_request(:get, format_url).with(headers: { "Authorization" => "Bearer secret" })
      .to_return(status: 202, body: { job_id: job_id, status: "pending" }.to_json,
                 headers: { "Location" => "https://untrusted.test/leak" })
  end

  def poll(body, status: 200)
    stub_request(:get, poll_url).with(headers: { "Authorization" => "Bearer secret" })
      .to_return(status: status, body: body.to_json)
  end

  before { allow(client).to receive(:sleep) }

  it "returns cached HTTP200 content without polling" do
    request = stub_request(:get, format_url).to_return(status: 200, body: result.to_json)
    expect(fetch).to eq(result)
    expect(request).to have_been_requested.once
    expect(a_request(:get, poll_url)).not_to have_been_made
  end

  it "polls pending and processing to completion, preserving auth and base path" do
    request = submit
    status = stub_request(:get, poll_url).with(headers: { "Authorization" => "Bearer secret" })
      .to_return(body: { status: "pending" }.to_json)
      .then.to_return(body: { status: "processing" }.to_json)
      .then.to_return(body: { status: "completed", result: result }.to_json)
    expect(fetch).to eq(result)
    expect(request).to have_been_requested.once
    expect(status).to have_been_requested.times(3)
    expect(client).to have_received(:sleep).with(1).twice
  end

  [422, 503, 504].each do |code|
    it "surfaces terminal #{code} job failures without resubmitting or retrying" do
      request = submit
      status = poll({ status: "failed", error: { code: code, message: "Model failed" } })
      expect { fetch }.to raise_error(described_class::ApiError, /#{job_id} failed: Model failed/) { |e| expect(e.code).to eq(code) }
      expect(request).to have_been_requested.once
      expect(status).to have_been_requested.once
      expect(client).not_to have_received(:sleep)
    end
  end

  [true, false].each do |async|
    it "preserves translation-fit details for #{async ? 'async' : 'synchronous'} failures" do
      if async
        submit
        poll({ status: "failed", error: fit_error })
      else
        stub_request(:get, format_url).to_return(status: 422, body: fit_error.to_json)
      end
      expect { fetch }.to raise_error(described_class::TranslationFitError) do |e|
        expect([e.attempts, e.best_length, e.max_char_length, e.locale]).to eq([3, 510, 480, "de-DE"])
      end
    end
  end

  it "retries transient HTTP polling failures on the same job" do
    request = submit
    status = stub_request(:get, poll_url).to_return(status: 503, body: '{"message":"busy"}')
      .then.to_return(status: 200, body: { status: "completed", result: result }.to_json)
    expect(fetch).to eq(result)
    expect(request).to have_been_requested.once
    expect(status).to have_been_requested.twice
  end

  it "recovers from a network timeout while polling" do
    submit
    status = stub_request(:get, poll_url).to_timeout.then
      .to_return(body: { status: "completed", result: result }.to_json)
    expect(fetch).to eq(result)
    expect(status).to have_been_requested.twice
  end

  [Net::OpenTimeout, Errno::ECONNREFUSED].each do |error|
    it "retries #{error} when opening the persistent polling connection" do
      request = submit
      status = poll({ status: "completed", result: result })
      starts = 0
      allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
        starts += 1
        raise error, "connection unavailable" if starts == 2
        original.call(*args, **kwargs, &block)
      end
      expect(fetch).to eq(result)
      expect(request).to have_been_requested.once
      expect(status).to have_been_requested.once
      expect(client).to have_received(:sleep).once
    end
  end

  it "reports persistent connection retry exhaustion as an API error without resubmitting" do
    request = submit
    starts = 0
    allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
      starts += 1
      raise Net::OpenTimeout, "connection unavailable" if starts > 1
      original.call(*args, **kwargs, &block)
    end
    expect { fetch }.to raise_error(described_class::ApiError, /Gave up after 6 consecutive network errors/)
    expect(request).to have_been_requested.once
    expect(starts).to eq(7)
    expect(client.instance_variable_get(:@http)).to be_nil
  end

  [403, 404].each do |code|
    it "fails immediately on HTTP #{code} while polling" do
      submit
      status = poll({ message: "Unavailable" }, status: code)
      expect { fetch }.to raise_error(described_class::ApiError, /HTTP #{code}/)
      expect(status).to have_been_requested.once
    end
  end

  [nil, "", "https://untrusted.test", "../../other"].each do |id|
    it "rejects invalid job ID #{id.inspect}" do
      stub_request(:get, format_url).to_return(status: 202, body: { job_id: id }.to_json)
      expect { fetch }.to raise_error(described_class::ApiError, /Invalid format-job submission/)
    end
  end

  [ { status: "unknown" }, { status: "completed" },
    { status: "completed", result: { content: "" } }, { status: "failed" } ].each do |body|
    it "fails on a malformed job contract: #{body}" do
      submit
      status = poll(body)
      expect { fetch }.to raise_error(described_class::ApiError)
      expect(status).to have_been_requested.once
    end
  end

  it "reports malformed JSON as an API error" do
    submit
    poll({})
    stub_request(:get, poll_url).to_return(body: "not json")
    expect { fetch }.to raise_error(described_class::ApiError, /Invalid JSON/)
  end

  context "with a one-second budget" do
    let(:client) { described_class.new(api_url: base, api_key: "secret", poll_interval: 10, timeout: 1) }
    before { allow(client).to receive(:sleep).and_call_original }

    it "bounds pending-job waits and closes the persistent session" do
      submit
      poll({ status: "processing" })
      expect { fetch }.to raise_error(described_class::ApiError, /Timed out after 1s waiting for format job #{job_id}/)
      expect(client.instance_variable_get(:@http)).to be_nil
      stub_request(:get, format_url).to_return(body: result.to_json)
      expect(fetch).to eq(result)
    end

    it "includes transient retry sleeps in the budget" do
      submit
      poll({ message: "Unavailable" }, status: 503)
      expect { fetch }.to raise_error(described_class::ApiError, /Timed out after 1s/)
    end

    it "bounds a slow initial HTTP request" do
      stub_request(:get, format_url).to_return do
        sleep(3)
        { status: 200, body: result.to_json }
      end
      expect { fetch }.to raise_error(described_class::ApiError, /Timed out after 1s waiting for format 'mobile-html'/)
    end
  end
end
