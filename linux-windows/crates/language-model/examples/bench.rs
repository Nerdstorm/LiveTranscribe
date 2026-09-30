//! Replays chat requests through a language model and writes each reply with its timings, one JSON
//! line each, in the formats the Mac's cleanup bench reads and writes.
//!
//! ```text
//! cargo run -p lt-language-model --release --example bench -- \
//!     --model <folder> --requests <in.jsonl> --out <out.jsonl> [--device CPU] [--cache <dir>]
//! ```
//!
//! A request line:
//!
//! ```json
//! {"id": "…", "messages": [{"role": "system", "content": "…"}, {"role": "user", "content": "…"}],
//!  "thinking": false, "max_tokens": 64, "adapter": "medium",
//!  "sampling": {"temperature": 0.0, "top_p": 1.0, "top_k": 0, "seed": null}}
//! ```
//!
//! An output line:
//!
//! ```json
//! {"id": "…", "output": "…", "prompt_tokens": 812, "reply_tokens": 23, "prefill_ms": 950.1,
//!  "decode_ms": 800.2, "total_ms": 1750.3, "stop": "eos", "error": null}
//! ```
//!
//! `--summary <file>` also writes the load time, memory and latency percentiles as JSON. The first
//! request runs once first, unrecorded (`--warm-up 0` skips that).
//!
//! A request's `adapter` names the adapter it runs with (`"medium"`, `"deep"`), or is `"none"`,
//! `false` or missing for none; `true`, as the Mac's first request files have it, is
//! `--default-adapter` (`medium`). For a model with adapter inputs, the adapters in the model
//! folder's `adapters/<name>/` are loaded, and any `--adapter-dir <name>=<folder>`. `--adapter off`
//! runs every request without one.

use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use clap::{Parser, ValueEnum};
use lt_language_model::{LanguageModel, Message, Options, Request, Sampling};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Parser)]
#[command(about = "Replays chat requests through a language model, writing each reply and its timings")]
struct Arguments {
    /// The model's folder: openvino_model.xml and .bin, and the tokenizer's files.
    #[arg(long)]
    model: PathBuf,
    /// The requests, one JSON object a line.
    #[arg(long)]
    requests: PathBuf,
    /// Where the replies go, one JSON object a line.
    #[arg(long)]
    out: PathBuf,
    /// The OpenVINO device.
    #[arg(long, default_value = "CPU")]
    device: String,
    /// Where OpenVINO keeps compiled models between runs, as the app does.
    #[arg(long)]
    cache: Option<PathBuf>,
    /// The folder of an OpenVINO runtime to load, as the installed app loads its own
    /// (packaging/linux/fetch-openvino.sh puts one together); otherwise OpenVINO is found as
    /// INTEL_OPENVINO_DIR or the library path says.
    #[arg(long)]
    openvino: Option<PathBuf>,
    /// More device properties, KEY=VALUE, such as KV_CACHE_PRECISION=u8.
    #[arg(long = "property", value_parser = parse_property)]
    properties: Vec<(String, String)>,
    /// Whether requests run with adapters: as each says, or none for every request.
    #[arg(long, value_enum, default_value_t = AdapterChoice::Request)]
    adapter: AdapterChoice,
    /// An adapter to load, NAME=FOLDER, besides those in the model folder's adapters/.
    #[arg(long = "adapter-dir", value_parser = parse_property)]
    adapter_dirs: Vec<(String, String)>,
    /// The adapter a request's `"adapter": true` means.
    #[arg(long, default_value = "medium")]
    default_adapter: String,
    /// The seed for requests that sample at random and give none.
    #[arg(long, default_value_t = 0)]
    seed: u64,
    /// How many times the first request runs, unrecorded, before the rest.
    #[arg(long, default_value_t = 1)]
    warm_up: usize,
    /// Only the first this many requests.
    #[arg(long)]
    limit: Option<usize>,
    /// Stops each reply after this long, as a cleanup deadline would.
    #[arg(long)]
    deadline_ms: Option<u64>,
    /// Where the summary goes, as JSON.
    #[arg(long)]
    summary: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
enum AdapterChoice {
    Request,
    Off,
}

fn parse_property(text: &str) -> Result<(String, String), String> {
    text.split_once('=')
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .ok_or_else(|| format!("{text:?} isn't KEY=VALUE"))
}

#[derive(Deserialize)]
struct RequestLine {
    id: String,
    messages: Vec<Message>,
    #[serde(default)]
    thinking: bool,
    max_tokens: usize,
    #[serde(default)]
    adapter: Option<AdapterField>,
    #[serde(default)]
    sampling: Option<SamplingLine>,
}

/// A request's adapter: by name, `"none"` for none, or on or off, as the Mac's first requests
/// said.
#[derive(Deserialize)]
#[serde(untagged)]
enum AdapterField {
    On(bool),
    Name(String),
}

/// The adapter name a request gives for none.
const NO_ADAPTER: &str = "none";

#[derive(Deserialize)]
struct SamplingLine {
    #[serde(default)]
    temperature: f32,
    #[serde(default = "one")]
    top_p: f32,
    #[serde(default)]
    top_k: usize,
    #[serde(default)]
    seed: Option<u64>,
}

fn one() -> f32 {
    1.0
}

#[derive(Serialize)]
struct OutputLine<'a> {
    id: &'a str,
    output: &'a str,
    prompt_tokens: usize,
    reply_tokens: usize,
    prefill_ms: f64,
    decode_ms: f64,
    total_ms: f64,
    stop: Option<&'static str>,
    error: Option<String>,
}

/// One recorded reply's numbers, for the summary.
struct Measured {
    prompt_tokens: usize,
    reply_tokens: usize,
    decode_steps: usize,
    prefill_ms: f64,
    decode_ms: f64,
    total_ms: f64,
    stop: &'static str,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let arguments = Arguments::parse();
    let lines: Vec<String> = BufReader::new(File::open(&arguments.requests)?)
        .lines()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|line| !line.trim().is_empty())
        .take(arguments.limit.unwrap_or(usize::MAX))
        .collect();
    let load_average_before = load_average();

    if let Some(folder) = &arguments.openvino {
        lt_language_model::runtime::use_openvino_in(folder.clone());
    }
    let options = Options {
        device: arguments.device.clone(),
        cache: arguments.cache.clone(),
        properties: arguments.properties.clone(),
    };
    let started = Instant::now();
    let mut model = LanguageModel::open(&arguments.model, &options)?;
    let load_ms = started.elapsed().as_secs_f64() * 1_000.0;
    let rss_after_load_mb = memory("VmRSS");
    let anonymous_after_load_mb = memory("RssAnon");
    if model.takes_adapters() && arguments.adapter == AdapterChoice::Request {
        for (name, folder) in adapter_folders(&arguments)? {
            model.load_adapter(&name, &folder)?;
        }
    }
    let adapters: Vec<serde_json::Value> = model
        .adapters()
        .iter()
        .map(|adapter| {
            json!({"name": adapter.name(), "rank": adapter.rank(), "scale": adapter.scale(), "base": adapter.base()})
        })
        .collect();
    eprintln!(
        "Loaded {} on {} in {load_ms:.0} ms (adapter inputs: {}, adapters: {}); {} requests",
        arguments.model.display(),
        model.device(),
        model.takes_adapters(),
        serde_json::to_string(&adapters)?,
        lines.len()
    );

    let requests: Vec<Result<(String, Request), String>> = lines.iter().map(|line| parse(line, &arguments)).collect();
    if let Some(Ok((_, first))) = requests.first() {
        for _ in 0..arguments.warm_up {
            model.generate(first, &|| false)?;
        }
    }

    let mut out = BufWriter::new(File::create(&arguments.out)?);
    let mut measured = Vec::new();
    let mut errors = 0;
    let run_started = Instant::now();
    for (index, request) in requests.iter().enumerate() {
        let (id, result) = match request {
            Ok((id, request)) => {
                let deadline = arguments
                    .deadline_ms
                    .map(|milliseconds| Instant::now() + Duration::from_millis(milliseconds));
                let started = Instant::now();
                let reply = model.generate(request, &|| deadline.is_some_and(|deadline| Instant::now() >= deadline));
                (
                    id.as_str(),
                    reply.map(|reply| (reply, started.elapsed().as_secs_f64() * 1_000.0)),
                )
            }
            Err(error) => {
                errors += 1;
                write_line(&mut out, &error_line("", error.clone()))?;
                continue;
            }
        };
        match result {
            Ok((reply, total_ms)) => {
                let line = OutputLine {
                    id,
                    output: &reply.text,
                    prompt_tokens: reply.prompt_tokens,
                    reply_tokens: reply.reply_tokens,
                    prefill_ms: round(reply.prefill_ms),
                    decode_ms: round(reply.decode_ms),
                    total_ms: round(total_ms),
                    stop: Some(reply.stop.name()),
                    error: None,
                };
                write_line(&mut out, &line)?;
                measured.push(Measured {
                    prompt_tokens: reply.prompt_tokens,
                    reply_tokens: reply.reply_tokens,
                    decode_steps: reply.decode_steps(),
                    prefill_ms: reply.prefill_ms,
                    decode_ms: reply.decode_ms,
                    total_ms,
                    stop: reply.stop.name(),
                });
            }
            Err(error) => {
                errors += 1;
                write_line(&mut out, &error_line(id, error.to_string()))?;
            }
        }
        if (index + 1) % 25 == 0 {
            eprintln!(
                "{} of {} ({:.0} s)",
                index + 1,
                requests.len(),
                run_started.elapsed().as_secs_f64()
            );
        }
    }
    out.flush()?;

    let summary = summarise(&measured, errors);
    let summary = json!({
        "model": arguments.model,
        "requests_file": arguments.requests,
        "device": model.device(),
        "takes_adapters": model.takes_adapters(),
        "adapters": adapters,
        "adapter": format!("{:?}", arguments.adapter).to_lowercase(),
        "properties": arguments.properties,
        "cache": arguments.cache,
        "load_ms": round(load_ms),
        "rss_after_load_mb": rss_after_load_mb,
        "rss_anonymous_after_load_mb": anonymous_after_load_mb,
        "rss_peak_mb": memory("VmHWM"),
        // The resident set at the end, split into memory of its own and the model's mapped file.
        "rss_end_mb": memory("VmRSS"),
        "rss_anonymous_end_mb": memory("RssAnon"),
        "rss_file_end_mb": memory("RssFile"),
        "load_average_before": load_average_before,
        "load_average_after": load_average(),
        "run_s": round(run_started.elapsed().as_secs_f64()),
        "results": summary,
    });
    eprintln!("{}", serde_json::to_string_pretty(&summary)?);
    if let Some(path) = &arguments.summary {
        std::fs::write(path, serde_json::to_string_pretty(&summary)?)?;
    }
    Ok(())
}

fn parse(line: &str, arguments: &Arguments) -> Result<(String, Request), String> {
    let request: RequestLine = serde_json::from_str(line).map_err(|error| format!("unreadable request: {error}"))?;
    let sampling = request.sampling.map_or(Sampling::Greedy, |sampling| {
        Sampling::from_settings(
            sampling.temperature,
            sampling.top_p,
            sampling.top_k,
            sampling.seed.unwrap_or(arguments.seed),
        )
    });
    Ok((
        request.id,
        Request {
            messages: request.messages,
            thinking: request.thinking,
            max_tokens: request.max_tokens,
            sampling,
            adapter: match (request.adapter, arguments.adapter) {
                (_, AdapterChoice::Off) | (None | Some(AdapterField::On(false)), _) => None,
                (Some(AdapterField::On(true)), _) => Some(arguments.default_adapter.clone()),
                (Some(AdapterField::Name(name)), _) if name == NO_ADAPTER => None,
                (Some(AdapterField::Name(name)), _) => Some(name),
            },
        },
    ))
}

/// The adapters to load: each `adapters/<name>/` in the model's folder that has adapter files,
/// then each `--adapter-dir`.
fn adapter_folders(arguments: &Arguments) -> std::io::Result<Vec<(String, PathBuf)>> {
    let mut folders = Vec::new();
    match std::fs::read_dir(arguments.model.join("adapters")) {
        Ok(entries) => {
            for entry in entries {
                let path = entry?.path();
                if path.join(lt_language_model::adapter::ADAPTER_WEIGHTS).is_file()
                    && let Some(name) = path.file_name().and_then(|name| name.to_str())
                {
                    folders.push((name.to_owned(), path.clone()));
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    folders.sort();
    folders.extend(
        arguments
            .adapter_dirs
            .iter()
            .map(|(name, folder)| (name.clone(), PathBuf::from(folder))),
    );
    Ok(folders)
}

fn error_line(id: &str, error: String) -> OutputLine<'_> {
    OutputLine {
        id,
        output: "",
        prompt_tokens: 0,
        reply_tokens: 0,
        prefill_ms: 0.0,
        decode_ms: 0.0,
        total_ms: 0.0,
        stop: None,
        error: Some(error),
    }
}

fn write_line(out: &mut impl Write, line: &OutputLine<'_>) -> std::io::Result<()> {
    serde_json::to_writer(&mut *out, line)?;
    out.write_all(b"\n")?;
    out.flush()
}

/// Percentiles of each timing, and the tokens.
fn summarise(measured: &[Measured], errors: usize) -> serde_json::Value {
    let percentiles = |values: Vec<f64>| {
        let mut values = values;
        values.sort_by(f64::total_cmp);
        let at = |fraction: f64| {
            if values.is_empty() {
                return 0.0;
            }
            let index = ((values.len() - 1) as f64 * fraction).round() as usize;
            round(values[index])
        };
        let mean = values.iter().sum::<f64>() / values.len().max(1) as f64;
        json!({"p50": at(0.5), "p95": at(0.95), "max": at(1.0), "mean": round(mean)})
    };
    let decode_rates: Vec<f64> = measured
        .iter()
        .filter(|reply| reply.decode_steps > 0 && reply.decode_ms > 0.0)
        .map(|reply| reply.decode_steps as f64 * 1_000.0 / reply.decode_ms)
        .collect();
    let prefill_rates: Vec<f64> = measured
        .iter()
        .filter(|reply| reply.prefill_ms > 0.0)
        .map(|reply| reply.prompt_tokens as f64 * 1_000.0 / reply.prefill_ms)
        .collect();
    let count = |stop: &str| measured.iter().filter(|reply| reply.stop == stop).count();
    json!({
        "replies": measured.len(),
        "errors": errors,
        "stops": {"eos": count("eos"), "max_tokens": count("max_tokens"), "cancelled": count("cancelled")},
        "prompt_tokens": percentiles(measured.iter().map(|reply| reply.prompt_tokens as f64).collect()),
        "reply_tokens": percentiles(measured.iter().map(|reply| reply.reply_tokens as f64).collect()),
        "prefill_ms": percentiles(measured.iter().map(|reply| reply.prefill_ms).collect()),
        "prefill_tokens_per_s": percentiles(prefill_rates),
        "decode_ms": percentiles(measured.iter().map(|reply| reply.decode_ms).collect()),
        "decode_tokens_per_s": percentiles(decode_rates),
        "total_ms": percentiles(measured.iter().map(|reply| reply.total_ms).collect()),
    })
}

fn round(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

/// A line of /proc/self/status, in MB (Linux only).
fn memory(field: &str) -> Option<f64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|line| line.starts_with(field))?;
    let kilobytes: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(round(kilobytes / 1_024.0))
}

/// The system's load average over 1, 5 and 15 minutes (Linux only).
fn load_average() -> Option<Vec<f64>> {
    let text = std::fs::read_to_string("/proc/loadavg").ok()?;
    text.split_whitespace()
        .take(3)
        .map(|value| value.parse().ok())
        .collect()
}
