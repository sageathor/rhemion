# Third-party notices

Rhemion is MIT-licensed (see [LICENSE](LICENSE)). It builds on the following work, with thanks.

## Included in the app

### FluidAudio
On-device speech recognition on Apple platforms (CoreML).
<https://github.com/FluidInference/FluidAudio>, Apache License 2.0.
The license text, and the licenses of the components FluidAudio carries (NemoTextProcessing, fastcluster, VBx), are included in the app at `Rhemion.app/Contents/Resources/Licenses/`.

### Mulish
Interface typeface. <https://github.com/googlefonts/mulish>
Copyright 2016 The Mulish Project Authors.
SIL Open Font License 1.1. Full text in `deploy/fonts/OFL.txt` and in the app at `Rhemion.app/Contents/Resources/Licenses/Mulish-OFL.txt`.

## Downloaded on first run

### NVIDIA Parakeet TDT 0.6B v3
Speech recognition model by NVIDIA, CoreML conversion by FluidInference.
<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>,
<https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
Creative Commons Attribution 4.0 International (CC BY 4.0).
The model is downloaded directly from Hugging Face; it is not redistributed by this repository.
Rhemion is not affiliated with or endorsed by NVIDIA or Hugging Face.

## Optional, supplied by the user

### whisper.cpp
Rhemion can use a whisper.cpp binary that you install yourself. It is not bundled.
<https://github.com/ggml-org/whisper.cpp>, MIT License.
