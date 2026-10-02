# Music on kie.ai (Suno)

All music work goes through kie.ai: the song itself (Suno), its stems and its word timings. Fal is for images and animation only. Do not use Fal `Music3` to compose, `media:stems` (Demucs) to separate, or `audio:transcribe` / `gen:overlay` Whisper to time a song. Those tasks stay in the toolkit for upstream compatibility only.

| Need | Use |
|---|---|
| A new song | song-maker (below), Suno on kie.ai |
| Vocal stem for H3 lipsync and `media:mouth` | `kie:stems[audio/source.mp3,audio/stems]` |
| Word timings for overlays, `review:music` and lipsync targets | song-maker's `songs/takeN_words.json`, or `kie:words` |
| Kie balance before and after paid work | `kie:credit` |

## Making the song: song-maker

The house song builder is `C:\appz\rua-de-camoes-series\utilities\song-maker\run.py` (README beside it). It works for any lyric, not only Rua de Camões. It records an ElevenLabs v3 guide vocal of the lyric, hosts it on Kie, and has Suno (`/api/v1/generate/upload-cover`, model in the style file) cover it with the style. Every take is trimmed so the first word lands at 1.0 s.

1. **Lyrics come from the song-craft skill**, never freestyled. Print the complete lyric in chat with section labels and an estimated sung duration before paying for a take. Measured duration replaces the estimate once a take exists.
2. **Three input files** in `utilities\song-maker\input\`:
   - `<slug>.txt`: the guide script, one stanza per line as `SPEAKER: [tags] text`. Speakers resolve in `utilities\text-to-dialogue\voice_ids.json` (read-only).
   - `<slug>.suno.txt`: the sheet Suno sings, section markers like `[Verse 1]` and one bar per line. Leave out per-line singer labels, because labelled sheets make Suno loop. Say who sings what in the style string.
   - `<slug>.style.json`: `title`, `style`, `negativeTags` (200 characters at most), `model`, `speakers` (name to male/female), `styleWeight`, `weirdnessConstraint`, `audioWeight`. Name a `theme` to take a character's locked sound from `song-maker\themes.json`. Characters do not sing in their dialogue registry voice.
3. **Check, estimate, then build**, from `utilities\song-maker`:

   ```
   python lyric_check.py input\<slug>.suno.txt
   python run.py budget -i input\<slug>.txt --target-seconds 135
   python run.py full   -i input\<slug>.txt
   ```

   `budget` spends nothing. `full` refuses a lyric that will not fit, and `--force` overrides that. In Rua de Camões, run `python utilities\budget\budget.py check <amount>` before every paid call and `budget.py spend <amount> "<what>"` in the same turn.
4. **Output** in `utilities\song-maker\output\<slug>_<timestamp>\`:
   - `song.json`: `task_id`, plus one entry per take under `tracks` with `audio_id`, `seconds`, `first_word_s` (where the first word sat in Suno's untrimmed take) and `coverage`.
   - `songs\<slug>_takeN.mp3`: the trimmed takes.
   - `songs\takeN_words.json`: Suno's word timings, already moved onto the trimmed take as `[{w,s,e}]`.

   Listen to every take. Pick the take whose voices, ending and coverage fit the plan.

Initialize the video project with the chosen trimmed take as `--song`. Its words file is the project's timing source: copy it to `audio/words.json`, or set `words:` on a generation.

## Stems: `kie:stems`

```sh
ruby scripts/mv.rb --project /absolute/project 'kie:stems[audio/source.mp3,audio/stems]'
ruby scripts/mv.rb --project /absolute/project 'kie:stems[audio/source.mp3,audio/stems]' STEMS=split_stem
```

- The task uploads the project's own song file to Kie storage, runs `ai-music-api/separate-vocals`, downloads every returned stem, and decodes each one to WAV beside the MP3, for example `audio/stems/vocals.wav` and `audio/stems/instrumental.wav`.
- Separating the file rather than the Suno task keeps the stems on the song's timeline. A song-maker take is trimmed, so stems made from its `task_id` and `audio_id` would start `first_word_s - 1.0` seconds late. The task warns when a stem's length differs from the song by more than a quarter second.
- Kie lists these costs: `separate_vocal` (the default, vocals plus accompaniment) is 10 credits, `split_stem` (up to 12 stems, useful for drum-driven cuts) is 50 credits, and `split_stem_advanced` is 20 credits. Current prices are at https://kie.ai/pricing. Run `kie:credit` before and after to measure the real charge.
- **Kie charges every repeated call.** The receipt in `output/requests/kie-*.json` resumes the same task on a rerun; `NEW_REQUEST=1` pays again. Kie keeps stem URLs for 14 days, and the task downloads them immediately.
- Files over Kie's 20 MB upload limit are encoded to a 320k MP3 first.

## Word timings: `kie:words`

For a Suno track without a song-maker words file:

```sh
ruby scripts/mv.rb --project /absolute/project 'kie:words[<task_id>,<audio_id>,audio/words.json,<shift_seconds>]'
```

This calls Kie's timestamped-lyrics endpoint, strips section tags, and writes `[{w,s,e}]`. `shift_seconds` moves Suno's untrimmed timeline onto the local file. For a song-maker take it is `first_word_s - 1.0` from `song.json`; for an untrimmed Suno download it is 0.

When `audio/words.json` exists, or a generation sets `words:`:
- `review:music` reads the section's words from it instead of buying a Whisper transcript.
- `gen:overlay` builds its cues from it with no Fal call.
- `anim:prepare[audio/words.json]` prepares the same cues for a sketch.

Suno's alignment can drift on fast rap and held fado notes. Correct the times by listening, and record the corrections in `docs/TIMING.md`.

## Keys and approval

Kie tasks read `KIE_API_KEY`. The plugin has a sensitive `KIE_API_KEY` option that reaches the `music-video` MCP server as `KIE_API_KEY_PLUGIN`; when that option is unset, the server falls back to the launcher's `KIE_API_KEY`. Codex passes the variable through the server's `env_vars`. `credential_status` reports `kie_configured`.

`kie:stems` and `kie:words` need a recorded plan approval, like every paid Fal task. `kie:credit` does not. Put the stem and timing calls in the plan's cost section in credits.
