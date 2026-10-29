//! Recover codec errors that the upstream EGFX client only emits as warnings.
//! This scoped subscriber retains one error field, never packet or image data.

use std::fmt;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Dispatch, Event, Level, Metadata, Subscriber};

pub(crate) struct GraphicsDiagnostics {
    dispatch: Dispatch,
    error: Arc<Mutex<Option<String>>>,
}

impl GraphicsDiagnostics {
    pub(crate) fn new() -> Self {
        let error = Arc::new(Mutex::new(None));
        Self {
            dispatch: Dispatch::new(CodecErrors(error.clone())),
            error,
        }
    }

    pub(crate) fn process<T, E>(
        &self,
        process: impl FnOnce() -> std::result::Result<T, E>,
    ) -> Result<T>
    where
        E: std::error::Error + Send + Sync + 'static,
    {
        self.error.lock().unwrap().take();
        let result = tracing::dispatcher::with_default(&self.dispatch, process);
        result.with_context(|| match self.error.lock().unwrap().take() {
            Some(error) => format!("RDP 图形或会话处理失败（{error}）"),
            None => "RDP 图形或会话处理失败".to_owned(),
        })
    }
}

struct CodecErrors(Arc<Mutex<Option<String>>>);

impl Subscriber for CodecErrors {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.is_event()
            && metadata.target() == "ironrdp_egfx::client"
            && *metadata.level() <= Level::WARN
            && metadata.fields().field("error").is_some()
    }

    fn new_span(&self, _: &Attributes<'_>) -> Id {
        Id::from_u64(1)
    }
    fn record(&self, _: &Id, _: &Record<'_>) {}
    fn record_follows_from(&self, _: &Id, _: &Id) {}
    fn enter(&self, _: &Id) {}
    fn exit(&self, _: &Id) {}

    fn event(&self, event: &Event<'_>) {
        if self.enabled(event.metadata()) {
            event.record(&mut CodecErrorVisitor(&mut self.0.lock().unwrap()));
        }
    }
}

struct CodecErrorVisitor<'a>(&'a mut Option<String>);

impl Visit for CodecErrorVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "error" {
            *self.0 = Some(format!("{value:?}").chars().take(1024).collect());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codec_error_is_attached_only_to_its_own_packet() {
        let diagnostics = GraphicsDiagnostics::new();
        let error = diagnostics
            .process(|| {
                tracing::warn!(target: "unrelated", error = "sensitive", "ignored");
                tracing::warn!(target: "ironrdp_egfx::client", error = ?"MissingTileReference", "decode failed");
                Err::<(), _>(std::io::Error::other("invalid graphics"))
            })
            .unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("MissingTileReference"));
        assert!(!message.contains("sensitive"));
        let later = diagnostics
            .process(|| Err::<(), _>(std::io::Error::other("another packet")))
            .unwrap_err();
        assert!(!format!("{later:#}").contains("MissingTileReference"));
    }
}
