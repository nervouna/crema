<img src="design/AppIcon/Crema-Default.png" alt="Crema app icon" width="128" height="128">

# Crema

Local meeting notes for macOS. Record or import audio, transcribe it, generate meeting minutes, and ask questions with references to the transcript. Audio and text stay on your Mac; inference runs locally with MLX.

Crema is an early native SwiftUI app focused on Chinese meetings with English technical terms. The current interface and generated minutes use Simplified Chinese.

## Run from source

You need an Apple Silicon Mac running macOS 27 or later, Xcode 27.1 (the tested toolchain), and Python 3.11 or later. The model preparation script also uses `curl`.

```sh
git clone https://github.com/nervouna/crema.git
cd crema
python3 scripts/prepare-model.py --speech
python3 scripts/prepare-model.py
zsh scripts/build.sh
open .build/Build/Products/Release/Crema.app
```

Initial setup needs internet access to download Swift packages and model weights. The preparation script downloads pinned model revisions into `.models/` and verifies file sizes and available SHA-256 hashes. The app loads those local files and does not download models during inference.

The build uses ad hoc signing for local development. You can also open `Crema.xcodeproj` in Xcode and run the `Crema` scheme.

The default model paths point to this checkout's `.models/` directory. If you move the checkout or store the weights elsewhere, choose the corresponding directories in Crema's Settings.

## Use Crema

- Start a microphone recording with **Command-N**, or import an audio file with **Command-O**. Recording supports pause and resume.
- Stop a recording to start local transcription and minutes generation. Imported audio follows the same process.
- Review the timestamped transcript, play back the recording, and correct recognition errors. Retranscribing creates a copy and preserves the original meeting.
- Ask questions about the meeting and follow references back to the transcript.
- Export the minutes and transcript as Markdown. Add names and technical terms to the vocabulary in Settings.

Transcription currently requests Chinese recognition. Meeting minutes separate decisions, action items, and open questions; unclear speech is marked for review. Generated text still needs to be checked against the recording.

## Local models and data

Speech recognition uses **Qwen3-ASR 1.7B, 8-bit**. Minutes and questions use **Qwen3.5 4B, 4-bit**. The app loads models as needed and releases the language model before transcription.

Recordings, transcripts, minutes, and questions are stored under:

```text
~/Library/Application Support/Crema/Meetings/
```

Each meeting has its own directory containing its audio file and `meeting.json`. Model paths and vocabulary are stored in macOS user defaults. Crema requires microphone permission for recording; it has no account or cloud service to configure.

## Checks

After building, run the core checks without loading models:

```sh
check_dir=$(mktemp -d /private/tmp/crema-core.XXXXXX)
CREMA_DATA_DIRECTORY="$check_dir/Meetings" \
  .build/Build/Products/Release/Crema.app/Contents/MacOS/Crema --self-test
```

These checks cover local persistence, safe retranscription copies, transcript chunking, citation bounds, punctuation preservation, and stereo audio conversion. Success ends with `ALL CHECKS PASSED`.

For the full speech and language model checks, prepare both models first and run:

```sh
zsh scripts/check.sh
```

The script generates Chinese speech with the macOS Tingting voice, then runs transcription, minutes, and question-answering checks with network access denied to the app process. Tingting must already be available on the Mac. Results are written to a temporary directory printed by the script.

## App icon

The editable [Icon Composer document](Crema/AppIcon.icon) is integrated into the Xcode target. It combines a native background with transparent cup artwork, with the visual center adjusted for the handle. [Appearance previews](design/AppIcon/previews) include default, dark, clear, and tinted variants. The [generation prompt and composition settings](design/AppIcon/generation-prompts.txt) are included with the artwork.

## License

Crema is available under the [MIT License](LICENSE). Third-party dependencies and downloaded model weights retain their respective licenses; model weights are not included in this repository.
