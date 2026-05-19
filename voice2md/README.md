# Voice2MD

Mac-native menubar app that watches a folder, transcribes any media file (audio or video) using whichever transcript source is fastest and most accurate — the **embedded Apple Voice Memos transcript** if the `.m4a` was recorded on iOS 18 / macOS Sequoia or later (instant, no model load, no API call), otherwise local **`whisper.cpp`** — and writes a Markdown note ready to paste into a wiki.

By default the output is the **raw transcript** with minimal frontmatter (no API call, no key required). Optionally, flip a single toggle to enrich with **Anthropic Claude**, **Azure OpenAI**, or a **local Ollama model** — adding a title, summary, key ideas, topics, action items, and entities.

## Prerequisites

- macOS 14 or later
- Xcode 15 or later (for building)
- **None of the AI providers are required for the default workflow.** Optional, only if you want AI enrichment:
  - an **Anthropic API key** (`https://console.anthropic.com`),
  - an **Azure OpenAI** resource with a deployment (key + endpoint URL + deployment name),
  - or a **local Ollama** install (`brew install ollama`, `ollama serve`, then `ollama pull <model>`) — no key, no quota, runs offline.

  All three are switchable at any time in Settings → AI.
- One-time CLI dependencies, all via Homebrew:
  ```
  brew install xcodegen whisper-cpp ffmpeg
  ```

## Building

### Install as a real app (no Xcode needed afterwards)

```sh
git clone <this repo>
cd voice-memos-to-md
./scripts/install.sh
```

That builds Release, copies the `.app` to `/Applications`, and launches it. After this you can quit + relaunch from Spotlight, Launchpad, Finder, etc. — Xcode is no longer involved. Toggle **Launch at Login** in Settings → General to have it start with macOS.

To uninstall: quit the app and `rm -rf /Applications/Voice2MD.app`. To wipe state too, see [How to clean all cache](#cleaning-state).

### Develop (run from Xcode)

```sh
xcodegen generate           # generates Voice2MD.xcodeproj from project.yml
open Voice2MD.xcodeproj
```

In Xcode press ⌘R. The app appears as a waveform icon in the menu bar (no Dock icon — `LSUIElement = YES`).

To run a Debug build from the terminal:
```sh
xcodebuild -project Voice2MD.xcodeproj -scheme Voice2MD -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Voice2MD-*/Build/Products/Debug/Voice2MD.app
```

## First-launch tour

1. Click the menu bar icon → **Settings…**
2. **AI** tab — *optional, off by default*:
   - The toggle at the top, **Use AI to extract structure**, is **off** by default. With it off, the app writes a plain transcript markdown — no API call needed. The rest of the AI tab is greyed out until you flip it on.
   - When you turn it on, pick a **Provider**: **Anthropic**, **Azure OpenAI**, or **Ollama (local)**. All three are independent — switching providers does not lose the others' settings.
   - **Anthropic**: paste your API key (Keychain account `anthropic-api-key`); pick a model (`claude-haiku-4-5` default, `claude-sonnet-4-6` for harder memos).
   - **Azure OpenAI**: paste your API key (Keychain account `azure-openai-api-key`), the endpoint URL (e.g. `https://my-resource.openai.azure.com`), the deployment name (e.g. `gpt-4o` — the deployment, not the underlying model), and optionally the API version (default `2024-08-01-preview`). Azure mode uses Chat Completions with `response_format: json_object`.
   - **Ollama (local)**: endpoint defaults to `http://localhost:11434`; type the model name you've pulled (e.g. `llama3.1:8b`, `qwen2.5:14b`). No key. The pipeline calls `/api/chat` with `format=json` and `num_ctx=8192`. **Use a 7B+ parameter model** — smaller models often produce malformed JSON that the repair loop can't recover.
   - Click **Test Connection** → expect a green ✓.
3. **Transcription** tab:
   - Pick a Whisper model. `small.en` is the default; `medium.en` or `large-v3-turbo` for multi-speaker / noisy memos.
   - Click **Download** → progress bar runs to 100%; the `.bin` lands in `~/Library/Application Support/Voice2MD/models/`.
   - Confirm `ffmpeg` and `whisper-cli` show **Found**. If not, copy the `brew install` line and run it.
4. **General** tab:
   - **Choose…** an Input folder (e.g. `~/Documents/VoiceMemosIn`).
   - **Choose…** an Output folder (e.g. `~/Documents/VoiceMemosOut`).
   - (Optional) toggle **Launch at Login**. The status text below clarifies whether macOS needs you to approve in *System Settings → General → Login Items*.

Close Settings. The watcher is now running.

## Using

Drop any supported media file into the input folder. The menu bar icon flips to a circle while processing; the menu's status line shows `Processing <name>…`. A `YYYY-MM-DD_HHMM_<slug>.md` lands in the output folder.

### Default mode (no AI)

Slug = sanitized source filename. E.g. `Piotr 1:1 .m4a` → `2026-05-07_1939_piotr-1-1.md`:

```yaml
---
title: 'Piotr 1:1'
recording_date: 2026-05-07T19:39:00Z
processing_date: 2026-05-08T11:00:00Z
source_media: 'Piotr 1:1 .m4a'
source_format: m4a
source_sha256: abc123…
duration_sec: 6986
transcribed_with: 'apple-embedded'
---

# Piotr 1:1

[the transcript text, verbatim]
```

`transcribed_with` is `apple-embedded` when the `.m4a` carried the system transcript, otherwise the whisper model id (e.g. `small.en`). No API call was made. The transcript appears under an H1 derived from the filename.

### AI-enriched mode (toggle on)

Slug = AI-derived title; richer frontmatter and structured sections:

```yaml
---
title: 'Q3 Roadmap Review'
recording_date: 2026-05-07T14:30:00Z
processing_date: 2026-05-07T14:31:12Z
source_media: 'memo.m4a'
source_format: m4a
source_sha256: abc123…
duration_sec: 92
transcribed_with: 'small.en'
model: 'claude-haiku-4-5'
tags:
  - 'roadmap'
  - 'engineering'
---
```

…with these body sections: `Summary`, `Key Ideas`, `Topics`, `Action Items` (as `- [ ]` checkboxes), `Entities`, `Cleaned Transcript`.

### Supported input formats

`m4a, mp3, wav, aac, flac, ogg, opus, m4b, mp4, mov, mkv, webm, wma`. ffmpeg extracts audio from videos automatically.

### Apple Voice Memos fast path

iOS 18 / macOS Sequoia and later embed the system-generated transcript directly into the `.m4a` file as JSON inside the MP4 atom `moov/trak/udta/tsrp`. This app reads that atom in pure Swift (no `mp4extract` / bento4 dependency) and skips ffmpeg + whisper entirely when the transcript is present — extraction happens in milliseconds, free, offline. For older recordings or non-Apple-Memos audio, the pipeline falls back to local `whisper.cpp` exactly as before.

Credit for the atom path: [Thomas Countz's gist](https://gist.github.com/Thomascountz/287d7dd1e04674d22a6396433937cd29).

### Recording date

Pulled from the media file's metadata (`AVAsset.creationDate`), falling back to the file's mtime, falling back to `now`. So a memo recorded last Tuesday but exported today files under last Tuesday — chronologically correct in your wiki.

### Idempotency

`~/Library/Application Support/Voice2MD/processed.json` records the sha256 of every processed file. Drop the same memo twice and the second drop is a no-op.

To re-process: delete the corresponding `.md` AND remove the entry from `processed.json` (or just delete the file entirely to reset all history), then drop the source again.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Missing CLI tool: whisper-cli` | `brew install whisper-cpp`; quit & relaunch the app. |
| `Missing CLI tool: ffmpeg` | `brew install ffmpeg`. |
| Model download fails | Check network. The download is resumable in the sense that you can retry; partial files are removed automatically. |
| `Test Connection` returns 401 (Anthropic) | Key is wrong. Anthropic keys begin with `sk-ant-`. |
| `Test Connection` returns 401 (Azure) | Key is wrong, or doesn't have access to that deployment. |
| Azure: "endpoint not a valid URL" | Endpoint must include the scheme, e.g. `https://my-resource.openai.azure.com` (no trailing slash, no path). |
| Azure: "DeploymentNotFound" 404 | The deployment name in Settings doesn't match what's in your Azure resource. Check Azure AI Studio → Deployments. |
| Ollama: "Could not reach Ollama" | Run `ollama serve` (or check `launchctl list \| grep ollama` if installed via brew). |
| Ollama: extraction looks half-cooked | Use a bigger model. 1–3 B class often skips fields or repeats keys. `llama3.1:8b` or larger is the floor. |
| Launch at Login shows "Approval needed" | Open *System Settings → General → Login Items*, find Voice2MD, toggle on. |
| Settings window won't open | Click the menu bar icon → Settings… (`⌘,` if menu is open). |
| Processed-but-want-to-redo | Delete the `.md` plus its row in `processed.json`, drop the source again. |

Logs land in macOS Console under subsystem `com.adrianprecub.Voice2MD` (categories: `app`, `pipeline`, `claude`, `whisper`, `watcher`).

## How it works

```
file appears  →  FSEventStream callback
              →  size-stable debounce (3 s)
              →  sha256 + check ProcessedStore (skip if seen)
              →  read embedded Apple transcript (moov/trak/udta/tsrp atom)
                 IF MISSING:
                   ffmpeg → 16 kHz mono wav → whisper-cli → transcript
              →  one of:
                 - Anthropic /v1/messages (with cache_control: ephemeral)
                 - Azure /openai/deployments/{name}/chat/completions (response_format: json_object)
                 - Ollama /api/chat (format: json, num_ctx: 8192)
              →  render markdown + frontmatter
              →  write to output dir, append ProcessedStore
              →  menubar status updates
```

For **Anthropic**, prompt caching on the system block means each subsequent memo gets a cache hit on the schema/instructions — observable as `cache_read_input_tokens` in the API response. For **Azure OpenAI**, structured output is enforced via `response_format: { type: json_object }`; some Azure models also do automatic prefix caching but there's no explicit `cache_control` knob. For **Ollama**, `format: "json"` constrains output, and the lenient JSON schema decoder accepts realistic local-model output (e.g. omitted "empty" sub-fields like `entities.places`); a JSON repair loop catches the rest.

## Tests

```sh
xcodebuild -project Voice2MD.xcodeproj -scheme Voice2MD -destination 'platform=macOS' test
```

The `TranscriberIntegrationTests` test will be skipped unless you have downloaded the `small.en` model. Other tests run unconditionally and cover Sha256, ProcessedStore, Keychain, AppConfig defaults, ClaudeClient (via stubbed URLSession — request shape, prompt caching headers, retry, JSON repair), Slug, MarkdownRenderer (golden file), StatusModel state transitions, and Pipeline orchestration (skip-on-seen, missing-output-folder, write-collision).

## Out of scope

- No App Store distribution; no notarization or hardened runtime config beyond what local Run needs.
- No multi-language detection — English-only.
- No direct upload to a wiki — copy/paste or rsync the output folder.
- No speaker diarization. Multi-speaker memos transcribe as one voice. To add later: pre-pipeline `pyannote.audio` sidecar.

## Project layout

```
voice-memos-to-md/
├── app-plan.md                     # original plan with phase verifications
├── README.md
├── project.yml                     # xcodegen source of truth
├── Voice2MD.xcodeproj              # generated; gitignored
├── Voice2MD/
│   ├── Voice2MDApp.swift
│   ├── Info.plist                  # LSUIElement=YES
│   ├── Menu/                       # MenuBarView, StatusModel, Notifier
│   ├── Settings/                   # Settings tabs (General/AI/Transcription)
│   ├── Core/                       # AppConfig, Keychain, ProcessedStore, Watcher,
│   │                               # Transcriber, WhisperModelManager, ClaudeClient,
│   │                               # ExtractionSchema, MediaMetadata, MarkdownRenderer,
│   │                               # Pipeline, AppCoordinator
│   ├── Util/                       # Logger+App, Sha256, Slug
│   └── Resources/Prompts/extraction.system.txt
└── Voice2MDTests/                  # ~30 tests across the components
```
