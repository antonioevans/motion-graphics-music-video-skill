require "excon"
require "json"
require "uri"
require "logger"
require "fileutils"
require "digest"
require "securerandom"
require "time"

module Kie
  class Error < StandardError; end

  class RequestError < Error
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      super("kie request failed (HTTP #{status}): #{body}")
    end
  end

  # Thin Excon wrapper around the kie.ai APIs used for Suno music work:
  #   POST https://api.kie.ai/api/v1/jobs/createTask                  -> { code, data: { taskId } }
  #   GET  https://api.kie.ai/api/v1/jobs/recordInfo?taskId=           -> { data: { state, resultJson, failMsg } }
  #   POST https://api.kie.ai/api/v1/generate/get-timestamped-lyrics   -> { data: { alignedWords } }
  #   GET  https://api.kie.ai/api/v1/chat/credit                       -> { data: credits }
  #   POST https://kieai.redpandaai.co/api/file-stream-upload          -> { data: { downloadUrl, fileUrl } }
  # Kie answers some failures with HTTP 200 and a body code other than 200, so both are checked.
  class Client
    API = "https://api.kie.ai".freeze
    UPLOAD = "https://kieai.redpandaai.co/api/file-stream-upload".freeze
    # Kie deletes uploaded files after 24 hours to 3 days depending on the page; reuse a URL for less than a day.
    UPLOAD_REUSE_SECONDS = 20 * 3600

    attr_reader :logger

    def initialize(api_key: nil, logger: Logger.new($stderr), poll_interval: 5, timeout: 1200)
      @api_key = api_key || ENV["KIE_API_KEY"]
      raise Error, "Missing KIE_API_KEY; configure the plugin or set this environment variable for local development" if @api_key.to_s.strip.empty?
      @logger = logger
      @poll_interval = poll_interval
      @timeout = timeout
    end

    # Create + poll a market job. Returns [task_id, record]. `key` names the receipt; an identical
    # request resumes its saved task instead of paying again (Kie charges every repeated call).
    def run(model, input, key: [model, input])
      require_relative "../workflow/approval"
      Workflow::Approval.new.check!
      FileUtils.mkdir_p("output/requests")
      receipt = "output/requests/kie-#{Digest::SHA256.hexdigest(JSON.generate(key))}.json"
      File.open("#{receipt}.lock", File::CREAT | File::RDWR) do |lock|
        lock.flock(File::LOCK_EX)
        if File.exist?(receipt) && ENV["NEW_REQUEST"] != "1"
          task_id = JSON.parse(File.read(receipt)).fetch("task_id")
        else
          task_id = create(model, input)
          File.write("#{receipt}.tmp", JSON.pretty_generate(task_id: task_id, model: model))
          File.rename("#{receipt}.tmp", receipt)
        end
        logger.info("[kie] #{model} task_id=#{task_id}; receipt=#{receipt}")
        return [task_id, wait(task_id)]
      end
    end

    def create(model, input)
      body = request(:post, "#{API}/api/v1/jobs/createTask", body: JSON.generate(model: model, input: input))
      body.dig("data", "taskId") || raise(Error, "kie createTask returned no taskId: #{body}")
    end

    def record(task_id)
      request(:get, "#{API}/api/v1/jobs/recordInfo?taskId=#{URI.encode_www_form_component(task_id)}").fetch("data")
    end

    def wait(task_id)
      started = Time.now
      loop do
        data = record(task_id)
        case data["state"]
        when "success" then return data
        when "fail" then raise Error, "kie task #{task_id} failed: #{data["failCode"]} #{data["failMsg"]}"
        else logger.info("[kie]   #{data["state"]}")
        end
        raise Error, "kie task #{task_id} timed out after #{@timeout}s; rerun to resume it" if Time.now - started > @timeout
        sleep @poll_interval
      end
    end

    # Word timings Suno aligned for one of its tracks, on that track's own timeline.
    def aligned_words(task_id, audio_id)
      require_relative "../workflow/approval"
      Workflow::Approval.new.check!
      body = request(:post, "#{API}/api/v1/generate/get-timestamped-lyrics", body: JSON.generate(taskId: task_id, audioId: audio_id))
      Array(body.dig("data", "alignedWords"))
    end

    def credit = request(:get, "#{API}/api/v1/chat/credit").fetch("data")

    # Host a local file on Kie storage; returns a URL Kie models accept as audio_url.
    def upload(path, content_type: Media.mime_type(path))
      FileUtils.mkdir_p("output/uploads")
      cache = "output/uploads/kie-#{Digest::SHA256.hexdigest([Digest::SHA256.file(path).hexdigest, content_type].join(":"))}.json"
      File.open("#{cache}.lock", File::CREAT | File::RDWR) do |lock|
        lock.flock(File::LOCK_EX)
        if File.file?(cache) && ENV["REFRESH_UPLOAD"] != "1"
          saved = JSON.parse(File.read(cache))
          return saved.fetch("url") if Time.now - Time.parse(saved.fetch("uploaded_at")) < UPLOAD_REUSE_SECONDS
        end
        url = upload_uncached(path, content_type: content_type)
        File.write("#{cache}.tmp", JSON.generate(url: url, uploaded_at: Time.now.utc.iso8601))
        File.rename("#{cache}.tmp", cache)
        url
      end
    end

    def upload_uncached(path, content_type: Media.mime_type(path))
      boundary = "mv-#{SecureRandom.hex(16)}"
      body = String.new(encoding: Encoding::BINARY)
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"uploadPath\"\r\n\r\nmusic-video\r\n"
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(path)}\"\r\n"
      body << "Content-Type: #{content_type}\r\n\r\n" << File.binread(path) << "\r\n--#{boundary}--\r\n"
      data = request(:post, UPLOAD, body: body, content_type: "multipart/form-data; boundary=#{boundary}").fetch("data")
      url = data["downloadUrl"] || data["fileUrl"] || raise(Error, "kie upload returned no URL: #{data}")
      logger.info("[kie] uploaded #{path} -> #{url}")
      url
    end

    def download(url, path)
      File.open(path, "wb") do |f|
        streamer = ->(chunk, _remaining, _total) { f.write(chunk) }
        resp = Excon.get(url, response_block: streamer, middlewares: Excon.defaults[:middlewares] + [Excon::Middleware::RedirectFollower])
        raise RequestError.new(resp.status, "download #{url}") unless resp.status == 200
      end
      logger.info("[kie] downloaded #{url} -> #{path}")
      path
    end

    private

    def request(method, url, body: nil, content_type: "application/json")
      resp = Excon.new(url, read_timeout: 180, write_timeout: 300).request(
        method: method,
        body: body,
        headers: { "Authorization" => "Bearer #{@api_key}", "Content-Type" => content_type, "Accept" => "application/json" },
        middlewares: Excon.defaults[:middlewares] + [Excon::Middleware::RedirectFollower]
      )
      raise RequestError.new(resp.status, resp.body) unless (200..299).cover?(resp.status)
      parsed = JSON.parse(resp.body)
      raise RequestError.new(parsed["code"], parsed["msg"]) if parsed.is_a?(Hash) && parsed.key?("code") && parsed["code"] != 200
      parsed
    end
  end
end
