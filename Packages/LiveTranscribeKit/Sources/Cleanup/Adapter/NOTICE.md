# Cleanup adapter

A LoRA adapter for [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) (as converted to MLX in
[mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit)) that
teaches it to resolve spoken self-corrections ("fuel efficiency in cars, sorry, buses" →
"fuel efficiency in buses") while keeping everything else as said.

- `adapters.safetensors`: the adapter weights.
- `adapter_config.json`: mlx's LoRA configuration, plus the base model and the commit the adapter
  was trained on (`base_model`, `base_revision`). The app loads the adapter only into that commit.

It was trained with the `Train` tool in this package on synthetic data only; see
`Packages/LiveTranscribeKit/Training/README.md` for the data, the command and the evaluation.
Qwen3 is licensed under the Apache License 2.0 by the Qwen team, Alibaba Cloud. The adapter is
part of this repository and released under its MIT License.
