# vlaserve

Serve a trained Vision-Language-Action (VLA) policy locally with one command, and drive a robot
with it. Loads LeRobot-format checkpoints (pi0.5 and SmolVLA verified bit-exact against LeRobot).

`pip install vlaserve` is the **robot-side client**: no torch, no LeRobot, a few MB. The policy
runs on a GPU machine, usually from the container image.

## GPU machine: run the server

```bash
docker pull mtbui2010/vlaserve:latest
docker run --gpus all -p 11450:11450 -v /path/to/checkpoints:/ckpt \
  mtbui2010/vlaserve:latest serve --host 0.0.0.0 /ckpt/my_run/checkpoints/last/pretrained_model
```

(or `pip install "vlaserve[server]"` on Python 3.12 with a torch build that matches your driver)

## Robot computer: ask for actions

```python
from vlaserve.client import PolicyClient, ChunkExecutor

client = PolicyClient("http://gpu-box:11450")
chunk = client.act(images={"front": frame, "wrist": wrist}, state=q, task="open the drawer")
# chunk.actions: (chunk_size, action_dim), in robot units

ChunkExecutor(client, get_observation=read_robot, send_action=robot.command, fps=30).run(
    task="open the drawer", seconds=60)
```

The client resizes each camera frame to the policy's input size and sends it as JPEG (q95, 4:4:4)
by default; `PolicyClient(..., resize="off", encoding="raw")` sends the frames untouched.

```bash
vlaserve inspect <checkpoint or HF repo>             # cameras, state/action, chunk, licence
vlaserve check   <checkpoint> --profile my_robot.yaml # does the robot match the policy?
```

- Docs: https://mtbui2010.github.io/vlaserve/
- Source: https://github.com/mtbui2010/vlaserve
- Licence: Apache-2.0 (each model keeps its own licence; `vlaserve inspect` reports it)
