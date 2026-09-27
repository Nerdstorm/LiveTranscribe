# openvino 0.11.0, with one addition

This is the [openvino](https://crates.io/crates/openvino) crate 0.11.0 as published (from
[intel/openvino-rs](https://github.com/intel/openvino-rs) at commit
`e788316bae7baef13854d4abf5dd0e537a962062`, under the Apache License 2.0 in `LICENSE`), with one
change, in `src/core.rs`: `Core::compile_model_with_properties`, and the `libloading` dependency
it needs. The workspace uses it through `[patch.crates-io]` in `../../Cargo.toml`.

## Why

OpenVINO's NPU plugin runs a language model through its LLM pipeline (NPUW), which gives the
model the fixed shapes the NPU needs, only when `NPU_USE_NPUW` and the `NPUW_LLM` properties are
passed to `compile_model` itself. It doesn't read them from the core's or the device's properties
(`Core::set_property`), and the model's runtime options don't carry them either. Without them the
NPU refuses the language model ("to_shape was called on a dynamic shape"). openvino 0.11.0's
`Core::compile_model` passes no properties, and nothing else in the crate can.

The C function, `ov_core_compile_model`, takes its properties as C variadic arguments. With
runtime linking, openvino-sys declares every function with a fixed argument list, so the addition
opens the same shared library again (`libloading`) and takes the function with its variadic type.
It is only built with the `runtime-linking` feature, which is how the app uses the crate.

## Updating

When openvino-rs can pass properties to `compile_model`, drop this folder, the `[patch.crates-io]`
entry and the workspace's `exclude`, and use the crate's own call. Until then, to move to a new
release: copy the published crate here (`src`, `Cargo.toml`, `README.md`, and `LICENSE` from the
repository) and carry the addition over: the `compile_model_with_properties` method and the
`variadic` module at the end of `src/core.rs`, and `libloading` in `Cargo.toml`'s dependencies and
`runtime-linking` feature.
