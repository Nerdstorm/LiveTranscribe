//! prompts.jsonl: the request the model gets for each level, adapter, vocabulary, placeholder
//! list, text and context.

use serde::Deserialize;

use super::{OptionsJson, RequestJson, TemplateJson, assert_no_differences, prompts, read_lines};
use crate::{prompt, uses_adapter, warm_up_request};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PromptLine {
    name: Option<String>,
    adapted: bool,
    #[serde(rename = "override")]
    override_template: Option<TemplateJson>,
    options: OptionsJson,
    text: String,
    context: Vec<String>,
    context_limit: usize,
    request: RequestJson,
}

#[test]
fn the_prompts_match_the_mac_apps() {
    let lines: Vec<PromptLine> = read_lines("prompts.jsonl");
    assert!(lines.len() > 200, "prompts.jsonl was read");

    let mut differences = Vec::new();
    for (number, line) in lines.iter().enumerate() {
        let builder = prompts(line.adapted, line.override_template.as_ref());
        let options = line.options.options();
        let template = builder.template(&options);
        let request = prompt::request(&line.text, &line.context, line.context_limit, &template)
            .with_adapter(uses_adapter(options.level));
        let mut actual = vec![RequestJson::from(&request)];
        // The named requests must also be what their functions make.
        match line.name.as_deref() {
            Some("warm-up") => actual.push(RequestJson::from(&warm_up_request(&builder))),
            Some("cleanup") => assert_eq!(
                template,
                prompt::cleanup(),
                "the cleanup prompt is Light's without the adapter"
            ),
            Some("adapted") => assert_eq!(
                template,
                prompt::adapted(),
                "the adapted prompt is Medium's with the adapter"
            ),
            Some(name) => panic!("no named prompt {name:?}"),
            None => {}
        }
        for made in actual {
            if made != line.request {
                differences.push(format!(
                    "line {}: {:?} with {:?}, context {:?} (limit {})\n  Mac app: {:?}\n  this port: {made:?}",
                    number + 1,
                    line.text,
                    line.options,
                    line.context,
                    line.context_limit,
                    line.request
                ));
            }
        }
    }
    assert_no_differences("prompts.jsonl", &differences);
}
