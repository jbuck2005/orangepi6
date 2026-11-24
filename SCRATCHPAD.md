# Scratchpad

My working log for orangepi6, newest first. This branch is a scratch pad for sharing progress between my
sessions. It is never merged into `main`.

---

## 2026-11-24: Bird recognition plan

**Did:** wrote `docs/bird-recognition.md` (PR #26 into `main`): running a bird station's detection and BioCLIP 2
embeddings on the NPU, on this repo's open stack (no closed `libnoe` or ONNX Runtime provider). It moved here
from an earlier draft in the un-subscribird repo, which I reverted there. No NPU or CPU backend code goes into
un-subscribird.

**Status:** planning only, PR #26 open for my review.

**Next:** decide how the station should use the NPU (local service on the board, a standalone tool, or
something else), and whether `unsubscribird-forge` still has a job. Phase 1 (the hub's CLIP graph with float
embeddings) needs only the board.
