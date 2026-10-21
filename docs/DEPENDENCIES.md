# Dependencies and licenses

The Git repository contains the application source. Build-time SDKs, inference libraries, and speech models are downloaded from their upstream publishers into `native/local-*` directories, which are excluded from Git. `scripts/dependency_manifest.json` pins each downloaded file to an upstream revision, byte size, and SHA-256 or Git blob ID. The bootstrap verifies every file before extracting or using it.

The initial dependency download is about 570 MB. It includes the FluidAudio Swift package, NemoTextProcessing, Sherpa-ONNX for Apple Silicon, the Nemotron low and fast128 models, Community-1 speaker diarization models, LocalVQE, and CAM++ speaker embeddings. The app processes audio locally for capture and speaker analysis. ASR requests use the user's configured provider; this bootstrap does not send audio or call any paid service.

The public source code license does not replace upstream licenses for model and SDK materials:

| Material | Pinned source | License / notice |
| --- | --- | --- |
| FluidAudio | `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7` | Apache-2.0 |
| NemoTextProcessing | `v0.3.1` | Apache-2.0 |
| Sherpa-ONNX | `v1.13.8` | Apache-2.0 |
| CAM++ embedding model | `8be2a75c9ed7a590538b268e46fbb65e1aa9d208` | Apache-2.0 |
| LocalVQE | `4205430781c240397073d6f7bf676fb4c732fc12` | Apache-2.0 |
| Nemotron3 low and fast128 | `25a90f97f254428d4b30374b76af9c74fdee8327` | [OpenMDW 1.1](https://openmdw.ai/license/1-1/) |
| Community-1 Core ML conversion | `df2625ac79a7ac6b65ad868fee6d80f320da4232` | CC-BY-4.0; upstream LICENSE, NOTICE, PROVENANCE, and README are downloaded and kept with the models |

The bootstrap downloads these materials for local installation. It does not redistribute model binaries in this repository. The built app bundles the relevant Apache and OpenMDW license texts and a third-party notice; Community-1's upstream attribution and provenance files stay beside its downloaded models. If you redistribute a built app or its model files, retain all applicable upstream license and attribution notices and meet the license terms. Review the linked model license before use.

Python packages used by the included optional speaker reconciliation tools are pinned in `requirements.txt`. The macOS app itself needs Python 3.12 at runtime for its local workers; install the official universal2 Python distribution if `/usr/local/bin/python3` is not available. Building also requires macOS 15+, Apple Silicon, and Xcode Command Line Tools with Swift 6.
