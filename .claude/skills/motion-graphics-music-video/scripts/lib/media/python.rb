require "json"
require_relative "shell"

module Media
  # Runs analysis scripts in ./scripts with the local python3 (PIL + numpy)
  # and parses their JSON stdout.
  class Python < Shell
    SCRIPTS = File.expand_path("../../tools/python", __dir__)

    # Windows venvs keep the interpreter in Scripts/python.exe instead of bin/python3.
    VENV_PYTHON = Shell.windows? ? ".venv/Scripts/python.exe" : ".venv/bin/python3"

    def self.venv_python = File.expand_path(VENV_PYTHON)

    def executable = ENV["MV_PYTHON"] || (File.file?(self.class.venv_python) ? self.class.venv_python : "python3")

    def call(script, *args)
      JSON.parse(run(executable, File.join(SCRIPTS, script), *args, quiet: true))
    end

    # Share of low-saturation (hand-drawn / monochrome) vs colored pixels per image.
    def style_split(*images)
      call("style_split.py", *images)
    end

    # Per-frame position of a feature (box `size` centred at x, y in frame `from`) by template matching.
    def track_template(video, x, y, size, search = size, from = 0)
      call("track_template.py", video, x.to_s, y.to_s, size.to_s, search.to_s, from.to_s)
    end

    # Character cut out of a video/still into transparent PNGs in `out` (scripts/cutout.py): key "paper" or "green",
    # box [x, y, w, h], seed [x, y], frames, start, scale. Returns { "frames", "w", "h", "box", "scale" }.
    def cutout(source, out, key, box: nil, seed: nil, frames: nil, start: nil, scale: nil)
      args = [source, out, key]
      args += ["--box", *box] if box
      args += ["--seed", *seed] if seed
      { "--frames" => frames, "--start" => start, "--scale" => scale }.each { |flag, v| args += [flag, v] if v }
      call("cutout.py", *args.map(&:to_s))
    end

    # RMS loudness + vocal-band energy per window, for a mono wav.
    def audio_energy(wav, window: 0.5)
      call("audio_energy.py", wav, window.to_s)
    end
  end
end
