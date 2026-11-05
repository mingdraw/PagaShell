//! Incremental, ordered render data. ANSI/UTF-8 parsing and scrollback stay in Rust.

#[derive(Clone, Debug)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct TerminalFrame {
    /// Transport sequence, acknowledged only after Dart applies the whole frame.
    pub frame_id: u32,
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

impl From<crate::terminal::TerminalFrame> for TerminalFrame {
    fn from(frame: crate::terminal::TerminalFrame) -> Self {
        Self {
            frame_id: 0,
            columns: frame.columns,
            rows: frame.rows,
            alternate: frame.alternate,
            cursor_x: frame.cursor_x,
            cursor_y: frame.cursor_y,
            modes: frame.modes,
            cursor_blink: frame.cursor_blink,
            trim_front: frame.trim_front,
            keep_rows: frame.keep_rows,
            append_rows: frame.append_rows,
            lines: frame.lines.into_iter().map(Into::into).collect(),
            title: frame.title,
            bell: frame.bell,
        }
    }
}

impl From<crate::terminal::TerminalLine> for TerminalLine {
    fn from(line: crate::terminal::TerminalLine) -> Self {
        Self {
            id: line.id,
            wrapped: line.wrapped,
            cells: line.cells,
            clusters: line.clusters.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<crate::terminal::TerminalCluster> for TerminalCluster {
    fn from(cluster: crate::terminal::TerminalCluster) -> Self {
        Self {
            column: cluster.column,
            text: cluster.text,
        }
    }
}
