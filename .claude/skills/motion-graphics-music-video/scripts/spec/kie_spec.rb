require_relative "spec_helper"

RSpec.describe "Kie music HTTP contracts", :core do
  def stub_kie(state: "success", result: { vocal_separation_info: { vocal_url: "https://file.test/s/3d7021c9-fa8b-4eda-91d1-3b9297ddb172_Vocals.mp3", origin_url: "" } })
    created = []
    Excon.defaults[:mock] = true
    Excon.stub({ method: :post, host: "api.kie.ai", path: "/api/v1/jobs/createTask" }) do |req|
      created << { body: JSON.parse(req[:body]), auth: req[:headers]["Authorization"] }
      { status: 200, body: JSON.generate(code: 200, msg: "success", data: { taskId: "kie-task-1" }) }
    end
    Excon.stub({ method: :get, host: "api.kie.ai", path: "/api/v1/jobs/recordInfo" },
      { status: 200, body: JSON.generate(code: 200, msg: "success", data: { taskId: "kie-task-1", state: state, failMsg: "rejected audio",
        param: JSON.generate(input: { audio_url: "https://upload.test/source.mp3" }), resultJson: JSON.generate(result) }) })
    created
  end

  it "reads only an explicit key or KIE_API_KEY" do
    ENV.delete("KIE_API_KEY")
    expect { Kie::Client.new }.to raise_error(Kie::Error, /Missing KIE_API_KEY/)
    ENV["KIE_API_KEY"] = "  "
    expect { Kie::Client.new }.to raise_error(Kie::Error, /Missing KIE_API_KEY/)
    ENV["KIE_API_KEY"] = "configured-test-key"
    expect { Kie::Client.new }.not_to raise_error
  end

  it "creates, polls and resumes an identical job from its receipt without paying twice" do
    with_workspace do
      approve
      created = stub_kie
      client = Kie::Client.new(api_key: "kie-fixture", poll_interval: 0)
      2.times do
        task_id, record = client.run("ai-music-api/separate-vocals", { audio_url: "https://upload.test/a.mp3", type: "separate_vocal" })
        expect(task_id).to eq("kie-task-1")
        expect(record["state"]).to eq("success")
      end
      expect(created.size).to eq(1)
      expect(created.first[:auth]).to eq("Bearer kie-fixture")
      expect(created.first[:body]).to eq("model" => "ai-music-api/separate-vocals", "input" => { "audio_url" => "https://upload.test/a.mp3", "type" => "separate_vocal" })
      expect(Dir["output/requests/kie-*.json"].size).to eq(1)
    end
  end

  it "refuses paid jobs before approval and surfaces failed tasks and body error codes" do
    with_workspace do
      client = Kie::Client.new(api_key: "kie-fixture", poll_interval: 0)
      expect(client).not_to receive(:create)
      expect { client.run("ai-music-api/separate-vocals", {}) }.to raise_error(/approval missing/)
      expect { client.aligned_words("t", "a") }.to raise_error(/approval missing/)
    end
    with_workspace do
      approve
      stub_kie(state: "fail")
      expect { Kie::Client.new(api_key: "kie-fixture", poll_interval: 0).run("m", {}) }.to raise_error(Kie::Error, /rejected audio/)
    end
    Excon.stubs.clear
    Excon.stub({ method: :get, host: "api.kie.ai", path: "/api/v1/chat/credit" }, { status: 200, body: JSON.generate(code: 402, msg: "Insufficient Credits") })
    expect { Kie::Client.new(api_key: "kie-fixture").credit }.to raise_error(Kie::RequestError, /Insufficient Credits/)
  end

  it "uploads multipart audio once a day and reuses the URL inside that window" do
    with_workspace do
      File.binwrite("song.mp3", "ID3 fixture bytes")
      Excon.defaults[:mock] = true
      uploads = []
      Excon.stub({ method: :post, host: "kieai.redpandaai.co" }) do |req|
        uploads << req
        { status: 200, body: JSON.generate(success: true, code: 200, msg: "File upload successful", data: { downloadUrl: "https://kieai.redpandaai.co/download/f1", fileUrl: "https://kieai.redpandaai.co/files/music-video/song.mp3" }) }
      end
      client = Kie::Client.new(api_key: "kie-fixture")
      2.times { expect(client.upload("song.mp3")).to eq("https://kieai.redpandaai.co/download/f1") }
      expect(uploads.size).to eq(1)
      body = uploads.first[:body]
      expect(uploads.first[:headers]["Content-Type"]).to start_with("multipart/form-data; boundary=")
      expect(body).to include("name=\"uploadPath\"", "music-video", "filename=\"song.mp3\"", "ID3 fixture bytes")
      cache = Dir["output/uploads/kie-*.json"].first
      File.write(cache, JSON.generate(url: "https://old.test/expired", uploaded_at: (Time.now - 25 * 3600).utc.iso8601))
      expect(client.upload("song.mp3")).to eq("https://kieai.redpandaai.co/download/f1")
      expect(uploads.size).to eq(2)
    end
  end

  it "names stems from vocal_separation_info and resultUrls and ignores the source" do
    two = { "resultJson" => JSON.generate(vocal_separation_info: { origin_url: "", vocal_url: "https://f.test/s/3d7021c9-fa8b-4eda-91d1-3b9297ddb172_Vocals.mp3",
      instrumental_url: "https://f.test/s/d92a13bf-c6f4-4ade-bb47-f69738435528_Instrumental.mp3" }), "param" => JSON.generate(input: { audio_url: "https://upload.test/x.mp3" }) }
    expect(Kie::Stems.stem_urls(two)).to eq("vocals" => "https://f.test/s/3d7021c9-fa8b-4eda-91d1-3b9297ddb172_Vocals.mp3",
      "instrumental" => "https://f.test/s/d92a13bf-c6f4-4ade-bb47-f69738435528_Instrumental.mp3")
    listed = { "resultJson" => JSON.generate(resultUrls: ["https://f.test/s/aadc51a3-4c88-4c8e-a4c8-e867c539673d_Backing_Vocals.mp3", "https://f.test/s/ac75c5ea-ac77-4ad2-b7d9-66e140b78e44_Drums.mp3"]) }
    expect(Kie::Stems.stem_urls(listed).keys).to eq(%w[backing_vocals drums])
    expect(Kie::Stems.stem_urls({ "resultJson" => "" })).to eq({})
  end

  it "writes Suno word timings as anim:prepare cues, without section tags, on the local timeline" do
    with_workspace do
      client = double("kie", aligned_words: [
        { "word" => "[Intro]\nMorto ", "startS" => 10.931, "endS" => 11.33 },
        { "word" => "[Verse]\n", "startS" => 20.0, "endS" => 20.1 },
        { "word" => "rua\n", "startS" => 13.111, "endS" => 14.601 }
      ])
      result = Kie::Words.new(client: client).fetch("task", "audio", "audio/words.json", shift: 9.931)
      expect(result[:count]).to eq(2)
      expect(JSON.parse(File.read("audio/words.json"))).to eq([{ "w" => "Morto", "s" => 1.0, "e" => 1.399 }, { "w" => "rua", "s" => 3.18, "e" => 4.67 }])
    end
  end

  it "reviews and overlays a Suno song from its word timings without buying a transcription" do
    words = file("song-words.json")
    json(words, [{ w: "[Intro]\nMorto ", s: 1.0, e: 1.4 }, { w: "papel, ", s: 1.6, e: 2.6 }, { w: "rua\n", s: 3.2, e: 4.6 }])
    stub_const("Pipeline::GENERATIONS", { "kie-words" => { steps: [], **Pipeline.section(24, 48), words: words } })
    project = Pipeline::Project.new("kie-words")
    music = Pipeline::Steps::Music.new(project: project, client: double("no Whisper"))
    expect(music.send(:transcribe)).to include(text: "Morto papel,", source: words)
    result = Pipeline::Steps::Overlay.new(project: project, client: double("no Whisper")).submit
    expect(result.request_id).to be_nil
    expect(result.output["chunks"]).to eq([{ "text" => "Morto", "timestamp" => [0.0, 0.4] }, { "text" => "papel,", "timestamp" => [0.6, 1.6] }])
  end
end

RSpec.describe "Kie stems on the song's own timeline", :media do
  it "uploads the project's song, downloads every stem and decodes it to WAV beside the MP3" do
    with_workspace do
      approve
      song = tone(File.expand_path("song.wav"), duration: 2)
      stem = File.expand_path("stem-source.mp3")
      ff.run("ffmpeg", "-y", "-v", "error", "-i", song, "-c:a", "libmp3lame", "-b:a", "192k", stem)
      client = Kie::Client.new(api_key: "kie-fixture", logger: Logger.new(File::NULL))
      allow(client).to receive(:upload).with(song).and_return("https://upload.test/song.wav")
      expect(client).to receive(:run).with("ai-music-api/separate-vocals", { audio_url: "https://upload.test/song.wav", type: "separate_vocal" }, key: ["ai-music-api/separate-vocals", Digest::SHA256.file(song).hexdigest, "separate_vocal"])
        .and_return(["kie-task-1", { "resultJson" => JSON.generate(vocal_separation_info: { vocal_url: "https://f.test/s/3d7021c9-fa8b-4eda-91d1-3b9297ddb172_Vocals.mp3", instrumental_url: "https://f.test/s/d92a13bf-c6f4-4ade-bb47-f69738435528_Instrumental.mp3", origin_url: "" }) }])
      allow(client).to receive(:download) { |_url, path| FileUtils.cp(stem, path); path }
      result = Kie::Stems.new(client: client, ff: ff).separate(song, "audio/stems")
      expect(result[:stems].map { |s| s[:name] }).to eq(%w[vocals instrumental])
      expect(File.file?("audio/stems/vocals.wav") && File.file?("audio/stems/vocals.mp3")).to be(true)
      expect(result[:stems].first[:seconds]).to be_within(0.1).of(2.0)
      expect { Kie::Stems.new(client: client, ff: ff).separate(song, "audio/stems", type: "karaoke") }.to raise_error(ArgumentError)
    end
  end
end
