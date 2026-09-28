# openvino 0.11.0, with two additions

This is the [openvino](https://crates.io/crates/openvino) crate 0.11.0 as published (from
[intel/openvino-rs](https://github.com/intel/openvino-rs) at commit
`e788316bae7baef13854d4abf5dd0e537a962062`, under the Apache License 2.0 in `LICENSE`), with two
additions, both built only with the `runtime-linking` feature, which is how the app uses the crate:

- `Core::compile_model_with_properties`, in `src/core.rs`, and the `libloading` dependency it
  needs;
- `load_from_folder`, in `src/runtime_folder.rs`, which loads OpenVINO from the folder an
  installed app ships it in.

The workspace uses it through `[patch.crates-io]` in `../../Cargo.toml`.

## Why `compile_model_with_properties`

OpenVINO's NPU plugin runs a language model through its LLM pipeline (NPUW), which gives the
model the fixed shapes the NPU needs, only when `NPU_USE_NPUW` and the `NPUW_LLM` properties are
passed to `compile_model` itself. It doesn't read them from the core's or the device's properties
(`Core::set_property`), and the model's runtime options don't carry them either. Without them the
NPU refuses the language model ("to_shape was called on a dynamic shape"). openvino 0.11.0's
`Core::compile_model` passes no properties, and nothing else in the crate can.

The C function, `ov_core_compile_model`, takes its properties as C variadic arguments. With
runtime linking, openvino-sys declares every function with a fixed argument list, so the addition
opens the same shared library again (`libloading`) and takes the function with its variadic type.

## Why `load_from_folder`

The Linux packages carry their own OpenVINO runtime, in `/usr/lib/live-transcribe/openvino` (or
the AppImage's `usr/share/live-transcribe/openvino`), which `openvino-finder` never searches: it
looks only at environment variables and the system's folders. openvino-sys can load the C API
from a path, but Intel's libraries have no RUNPATH, so the dynamic linker wouldn't find the core
library and TBB beside it; and their licence allows distributing them unmodified, so they aren't
patched. `load_from_folder` loads hwloc (for TBB's tbbbind), TBB and the core library first, each
by its full path, then the C API through openvino-sys, and remembers the C API's path, which
`compile_model_with_properties` then opens instead of asking `openvino-finder` again. The packages
have no symlinks, so each library is there once, under its soname (`libopenvino_c.so.2621`), and
`load_from_folder` finds it by its name with or without the version.

## Updating

When openvino-rs can pass properties to `compile_model` and load the runtime from an
application's folder, drop this folder, the `[patch.crates-io]` entry and the workspace's
`exclude`, and use the crate's own calls. Until then, to move to a new release: copy the published
crate here (`src`, `Cargo.toml`, `README.md`, and `LICENSE` from the repository) and carry the
additions over:

- the `compile_model_with_properties` method and the `variadic` module at the end of
  `src/core.rs`;
- `src/runtime_folder.rs`, and its `mod` and `pub use` lines in `src/lib.rs`;
- `libloading` in `Cargo.toml`'s dependencies and `runtime-linking` feature.
