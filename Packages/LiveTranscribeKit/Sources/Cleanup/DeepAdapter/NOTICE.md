# Deep cleanup adapter

A LoRA adapter for [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) (as converted to MLX in
[mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit)) that
teaches it the Deep cleanup level: resolving self-corrections across sentences ("The demo is on
Tuesday. Sorry, Wednesday." → "The demo is on Wednesday."), reading garbled corrections ("no,
sorry, the after tomorrow" → "the day after tomorrow"), fixing grammar and words the speech
recognizer misheard, and laying out emails and lists, while keeping names, negations, numbers,
dates and claims as said.

- `adapters.safetensors`: the adapter weights.
- `adapter_config.json`: mlx's LoRA configuration, plus the base model and the commit the adapter
  was trained on (`base_model`, `base_revision`). The app loads the adapter only into that commit,
  alongside the self-correction adapter in `../Adapter`, whose shape it shares.

It was trained with the `Train` tool in this package on synthetic data only; see
`Packages/LiveTranscribeKit/Training/README.md` for the data, the command and the evaluation.
Qwen3 is licensed under the Apache License 2.0 by the Qwen team, Alibaba Cloud. The adapter is
part of this repository and released under its MIT License.
