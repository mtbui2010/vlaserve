# CLAUDE.md — vlaserve rules

Read before changing code. Sibling of `../vision_serve` (Go, CV models); this one serves
Vision-Language-Action policies and is deliberately **Python**.

## What it is

One command to serve a trained VLA policy locally and drive a robot with it:

    vlaserve serve pi05-libero        # HTTP server, chunk-returning API
    vlaserve check MODEL --profile P  # robot vs policy, before anything moves

Goal: easy to use and general across future models. Not a research artefact; novelty is not a goal.

## Decisions already made (do not relitigate without the user)

1. **Python, with LeRobot as the default backend.** A Go/ONNX-only runtime was rejected: every
   new VLA would need its own export and a hand-port of its tokenizer and normalisation, and an
   export can silently break closed-loop behaviour (one SmolVLA ONNX study: LIBERO-Spatial 70% to 41%).
   LeRobot already implements ~20 policies with self-describing checkpoints; generality comes from
   that, not from us.
2. **The checkpoint is the manifest.** `config.json` + `policy_{pre,post}processor.json` + stats
   describe everything. Never require a hand-written manifest; the registry only adds aliases,
   pinned revisions and licences.
3. **Licences: record and warn, never block.** PaliGemma-based policies (pi0/pi0.5) are detected
   and reported as `gemma-terms`. Do not guess a licence into the registry; leave it out.
4. **API returns a whole action chunk.** The client (`ChunkExecutor`) owns timing: async refill,
   stale-action dropping. The server is stateless per request apart from the policy's own state.
5. **ONNX/TensorRT is a future, optional backend** behind `backends.Backend`. Not built yet.
6. **Eager by default**, even when a checkpoint says `compile_model: true`: max-autotune picks
   kernels by benchmark and breaks run-to-run parity (~1e-3), and the first call takes ~46 s.
   Opt in per model with `options: {compile: true}`.

## Rules

- **Parity with LeRobot is the correctness bar.** `tests/test_gpu_parity.py` compares our chunk
  with `lerobot.async_inference.PolicyServer._predict_action_chunk` on real checkpoints, same seed.
  Any change to preprocessing, dtype or postprocessing must keep it passing.
- **No server-side resize** (deliberate difference from LeRobot's policy server, which resizes to
  `config.json`'s shape). That shape can be stale: kaair_sim's SmolVLA declares smolvla_base's
  256x256 `camera1` for a 480x848 `head` camera, and squashing it would feed the policy a distorted
  view. Frames go through as sent, as in training; pi05/smolvla resize internally.
- **The spec comes from normaliser stats first, `config.json` second** (`spec.py`). Stats keys
  carry the dataset's own camera names (what clients send, before `rename_map`) and true
  state/action sizes.
- **Never modify a checkpoint on disk.** Old-LeRobot compatibility goes in `compat.py` as a
  registered subclass alias, after verifying the config fields are identical.
- **Caller mistakes are typed `VLAServeError`s that map to 4xx** (`server.STATUS`). Validate the
  observation (`PolicySpec.validate`) before the GPU sees it. Bound everything read from the wire
  (`codec.py`).
- **One inference at a time per model**, under its lock, in a worker thread. Never start GPU work
  for a disconnected client.
- Default port **11450**, bind `127.0.0.1`. Anyone who can reach the port can move the robot.
- Fast tests run by default (`pytest`); GPU tests are opt-in (`pytest -m gpu`) and need
  `HF_HOME=/mnt/nas/huggingface HF_HUB_OFFLINE=1 CUDA_VISIBLE_DEVICES=<free gpu>`.

## Environment (this machine)

- conda env **`vlaserve`**: Python 3.12, torch 2.10.0+cu128 (the driver supports CUDA 12.8 only;
  the default PyPI torch is cu130 and will not see the GPU), lerobot 0.6.1, onnxruntime-gpu.
- Checkpoints live on the NAS HF cache `/mnt/nas/huggingface`. Loading pi0.5 (~8 GB) from it takes
  ~4-5 min cold. The root disk is ~100% full: never copy weights onto it.
- The GPUs are shared. Check `nvidia-smi` and use a free one.

## Quy tắc phát triển chung (skill `dev-principles`)
Chi tiết và lint: `~/.claude/skills/dev-principles/SKILL.md`; cấu hình repo: `.dev-principles.json`.
1. **Tổng quát hóa:** không đặt dữ kiện riêng của một robot, ngôn ngữ, miền hay benchmark trong lõi; chúng là dữ liệu khai báo (manifest, gói ngôn ngữ, hồ sơ robot) có nhãn nguồn `sourced`/`assumed`; thiếu dữ liệu thì tính năng không làm gì. Luật an toàn và quyền hạn là cấu hình theo từng robot.
2. **Mô-đun:** mỗi tính năng/tùy chọn là một mô-đun đăng ký vào lõi; phân tầng, giới hạn kích thước hàm/file (baseline trong `.dev-principles.baseline.json`: không được tăng); khi tái cấu trúc phải chứng minh hành vi giống hệt (phát lại từng byte).
3. **Trước khi báo xong hoặc merge:** `python3 ~/.claude/skills/dev-principles/scripts/layers.py .`, `size_baseline.py . --check`, `literal_scan.py <thư mục lõi> --check --baseline .dev-principles.literals.json`.
