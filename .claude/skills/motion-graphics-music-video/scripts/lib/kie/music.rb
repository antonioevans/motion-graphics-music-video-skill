require "json"
require "fileutils"
require_relative "client"

module Kie
  # Suno vocal/instrument separation of a local song file. Separating the project's own file,
  # rather than the Suno task, keeps every stem on the song's timeline: song-maker trims its takes.
  class Stems
    MODEL = "ai-music-api/separate-vocals"
    TYPES = %w[separate_vocal split_stem split_stem_advanced].freeze
    MAX_UPLOAD_BYTES = 20 * 1024 * 1024
    NAMES = { "vocal" => "vocals" }.freeze

    def initialize(client: Client.new, ff: Media::FFmpeg.new)
      @client, @ff = client, ff
    end

    # Returns one entry per stem: { name:, mp3:, wav:, seconds: } beside the source duration.
    def separate(audio, out_dir, type: "separate_vocal")
      raise ArgumentError, "Stem type must be one of #{TYPES.join(", ")}" unless TYPES.include?(type)
      require_relative "../workflow/approval"
      Workflow::Approval.new.check!
      source = uploadable(audio)
      digest = Digest::SHA256.file(source).hexdigest
      task_id, record = @client.run(MODEL, { audio_url: @client.upload(source), type: type }, key: [MODEL, digest, type])
      urls = self.class.stem_urls(record)
      raise Error, "kie task #{task_id} returned no stem URLs: #{record["resultJson"]}" if urls.empty?
      FileUtils.mkdir_p(out_dir)
      source_seconds = @ff.duration(audio)
      stems = urls.map do |name, url|
        mp3 = @client.download(url, File.join(out_dir, "#{name}#{File.extname(URI(url).path).then { |e| e.empty? ? ".mp3" : e }}"))
        wav = @ff.extract_audio(mp3, File.join(out_dir, "#{name}.wav"))
        { name: name, mp3: mp3, wav: wav, seconds: @ff.duration(wav).round(3) }
      end
      off = stems.reject { |s| (s[:seconds] - source_seconds).abs <= 0.25 }
      @client.logger.warn("[kie] stem length differs from the song (#{source_seconds.round(3)}s): #{off.map { |s| "#{s[:name]} #{s[:seconds]}s" }.join(", ")}") if off.any?
      { task_id: task_id, source: audio, source_seconds: source_seconds.round(3), stems: stems }
    end

    # The result shape for this model is not documented beyond the callback's
    # vocal_separation_info, so read every *_url key, or a resultUrls list, out of resultJson.
    def self.stem_urls(record)
      found = {}
      walk = lambda do |node|
        case node
        when Hash
          node.each do |key, value|
            if value.is_a?(String) && key.end_with?("_url") && key != "origin_url" && value.start_with?("http")
              found[stem_name(key.delete_suffix("_url"))] ||= value
            else
              walk.(value)
            end
          end
        when Array
          node.each { |value| value.is_a?(String) && value.start_with?("http") ? (found[stem_name(file_label(value))] ||= value) : walk.(value) }
        when String
          walk.(JSON.parse(node)) if node.start_with?("{", "[")
        end
      end
      walk.(record["resultJson"])
      found
    end

    def self.stem_name(label)
      name = label.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
      NAMES.fetch(name, name)
    end

    # ".../3d7021c9-fa8b-4eda-91d1-3b9297ddb172_Vocals.mp3" -> "Vocals"
    def self.file_label(url)
      base = File.basename(URI(url).path, ".*")
      base.sub(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_/i, "")
    end

    private

    def uploadable(audio)
      return audio if File.size(audio) <= MAX_UPLOAD_BYTES
      FileUtils.mkdir_p("output/uploads")
      mp3 = File.join("output/uploads", "#{File.basename(audio, ".*")}-#{Digest::SHA256.file(audio).hexdigest[0, 12]}.mp3")
      @ff.run("ffmpeg", "-y", "-v", "error", "-i", audio, "-vn", "-c:a", "libmp3lame", "-b:a", "320k", mp3) unless File.file?(mp3)
      raise Error, "#{audio} is over Kie's 20MB upload limit even as a 320k MP3; cut it first" if File.size(mp3) > MAX_UPLOAD_BYTES
      mp3
    end
  end

  # Suno's own word alignment for one of its tracks, written as [{w,s,e}] for anim:prepare.
  # `shift` moves Suno's timeline onto the local file's (song-maker: first_word_s - 1.0).
  class Words
    def initialize(client: Client.new)
      @client = client
    end

    def fetch(task_id, audio_id, out, shift: 0.0)
      words = @client.aligned_words(task_id, audio_id).filter_map do |item|
        text = item["word"].to_s.gsub(/\[[^\]]*\]/, "").strip
        next if text.empty? || item["startS"].nil? || item["endS"].nil?
        { w: text, s: (item["startS"].to_f - shift).round(3), e: (item["endS"].to_f - shift).round(3) }
      end
      raise Error, "kie returned no aligned words for task #{task_id} audio #{audio_id}" if words.empty?
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, JSON.pretty_generate(words))
      { path: out, count: words.size, first: words.first, last: words.last }
    end
  end
end
