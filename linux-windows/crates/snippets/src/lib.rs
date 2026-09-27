//! The user's snippets: spoken triggers and the text they stand for. Mirrors the Mac app's
//! `Snippets` module (Packages/LiveTranscribeKit/Sources/Snippets).

mod snippet;
mod snippet_expander;
mod trigger_matching;

pub use snippet::Snippet;
pub use snippet_expander::SnippetExpander;
