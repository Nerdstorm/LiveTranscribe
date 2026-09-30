//! prompts.jsonl: the request the model gets for each level, adapter, vocabulary, placeholder
//! list, text and context, and for Deep in each kind of field, run each way it can be.

use serde::Deserialize;

use super::{DeepJson, OptionsJson, RequestJson, TemplateJson, assert_no_differences, deep, prompts, read_lines};
use crate::{CleanupExecutor, DeepCleanup, OutputGuard, prompt, warm_up_request};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PromptLine {
    name: Option<String>,
    adapted: bool,
    #[serde(rename = "override")]
    override_template: Option<TemplateJson>,
    deep: Option<DeepJson>,
    options: OptionsJson,
    text: String,
    context: Vec<String>,
    context_limit: usize,
    request: RequestJson,
}

#[test]
fn the_prompts_match_the_mac_apps() {
    let lines: Vec<PromptLine> = read_lines("prompts.jsonl");
    assert!(lines.len() > 300, "prompts.jsonl was read");

    let mut differences = Vec::new();
    let mut shipped_deep_checked = false;
    for (number, line) in lines.iter().enumerate() {
        let builder = prompts(line.adapted, line.override_template.as_ref());
        let options = line.options.options();
        let executor = CleanupExecutor::new(line.context_limit, 1.0, OutputGuard::default(), builder.clone())
            .with_deep(deep(line.deep.as_ref()));
        // The named requests must also be what their functions make.
        let made = match line.name.as_deref() {
            Some("warm-up") => warm_up_request(&builder),
            Some("cleanup") => {
                assert_eq!(
                    builder.template(&options),
                    prompt::cleanup(),
                    "the cleanup prompt is Light's without the adapter"
                );
                executor.request(&line.text, &line.context, &options)
            }
            Some("adapted") => {
                assert_eq!(
                    builder.template(&options),
                    prompt::adapted(),
                    "the adapted prompt is Medium's with the adapter"
                );
                executor.request(&line.text, &line.context, &options)
            }
            Some("deep-shipped") => {
                let recorded = line.deep.as_ref().expect("the shipped Deep is recorded in full");
                assert_eq!(
                    recorded.deep(),
                    DeepCleanup::SHIPPED,
                    "Deep runs as the Mac app ships it"
                );
                shipped_deep_checked = true;
                executor.request(&line.text, &line.context, &options)
            }
            Some(name) => panic!("no named prompt {name:?}"),
            None => executor.request(&line.text, &line.context, &options),
        };
        let made = RequestJson::from(&made);
        if made != line.request {
            differences.push(format!(
                "line {}: {:?} with {:?}, Deep {:?}, context {:?} (limit {})\n  Mac app: {:?}\n  this port: {made:?}",
                number + 1,
                line.text,
                line.options,
                line.deep,
                line.context,
                line.context_limit,
                line.request
            ));
        }
    }
    assert_no_differences("prompts.jsonl", &differences);
    assert!(shipped_deep_checked, "prompts.jsonl records how Deep ships");
}
