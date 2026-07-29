# Third-Party Notices

maiku bundles the following open-source components. Full license texts ship with each package
under `.build/checkouts/<package>/LICENSE` after `swift package resolve`.

## Swift packages

| Package | Version | License | Copyright |
|---|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | 0.18.0 | MIT | © 2024 argmax, inc. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Apache-2.0 | © FluidInference |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29.3 | MIT | © 2015–2024 Gwendal Roué |

Resolved transitively by the above:

| Package | Version | License |
|---|---|---|
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.1.9 | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 2.4.2 | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.1 | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.1 | Apache-2.0 |

## Models

maiku does not redistribute model weights. They are downloaded on your instruction, at first
run, from the sources below, and cached locally.

| Model | Source | License |
|---|---|---|
| Whisper (`tiny.en`, `base.en`, `small.en`, `large-v3`…) | OpenAI, converted to Core ML by argmax and distributed via Hugging Face `argmaxinc/whisperkit-coreml` | Weights MIT (OpenAI Whisper) |
| `pyannote_segmentation` | Distributed via Hugging Face by FluidInference | MIT (pyannote.audio) |
| `wespeaker_v2` | Distributed via Hugging Face by FluidInference | Apache-2.0 (WeSpeaker) |

Review the upstream model cards before using maiku commercially — model licenses are set by
their publishers and can change independently of this application.

The language model that organizes your notes runs inside **LM Studio**, which you install and
license separately. maiku neither bundles nor redistributes LM Studio or any of its models.

## Fonts

maiku uses the system typefaces supplied by macOS (SF Pro and SF Mono) for body and
monospaced text. No font files are bundled or redistributed.

## Artwork

The Clawd character is associated with Anthropic. No Clawd artwork is scraped, traced,
downloaded, or model-generated into this repository — every sprite present was supplied
directly by the project maintainer, who is responsible for their own authorization to use it.
As of this writing, only the `listening` state has real artwork; every other state still
renders a clearly labelled generic placeholder until art for it is supplied the same way.
See `Resources/Clawd/README.md` for the current per-state status.

maiku is an independent project and is not affiliated with, endorsed by, or sponsored by
Anthropic, OpenAI, Hugging Face, or LM Studio.
