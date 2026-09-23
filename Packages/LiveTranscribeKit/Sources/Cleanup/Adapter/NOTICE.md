# Cleanup adapter

The fine-tuned LoRA adapter for the cleanup model goes here, in mlx's format:

- `adapters.safetensors`: the adapter weights.
- `adapter_config.json`: mlx's LoRA configuration, plus the base model and the commit the adapter
  was trained on (`base_model`, `base_revision`). The app applies the adapter only to that commit.

Without these files the app uses the base model with its strict prompt.
