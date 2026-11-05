//! Incremental, ordered render data. ANSI/UTF-8 parsing and scrollback stay in Rust.

#[derive(Clone, Debug)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct TerminalFrame {
    pub columns: u32,
    pub rows: u32,
    pub alternate: bool,
    pub cursor_x: u32,
    pub cursor_y: u32,
    /// Official alacritty TermMode bits, pinned to core version 0.26.0.
    pub modes: u32,
    pub cursor_blink: bool,
    /// Apply to the active display buffer: trim front, keep prefix, append IDs.
    pub trim_front: u32,
    pub keep_rows: u32,
    pub append_rows: Vec<u32>,
    pub lines: Vec<TerminalLine>,
    pub title: Option<String>,
    pub bell: bool,
}

#[derive(Clone, Debug)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct TerminalLine {
    pub id: u32,
    /// This row continues the preceding row (the xterm renderer convention).
    pub wrapped: bool,
    /// Four u32s per column: foreground, background, attributes, codepoint/width.
    pub cells: Vec<u32>,
    pub clusters: Vec<TerminalCluster>,
}

#[derive(Clone, Debug)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct TerminalCluster {
    pub column: u32,
    pub text: String,
}
