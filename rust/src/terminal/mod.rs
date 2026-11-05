//! Single-owner terminal emulator. Only changed rows cross the Flutter bridge.

use std::sync::{Arc, Mutex};

mod frame;
#[cfg(test)]
mod frame_tests;
mod tracking;
pub use frame::{TerminalCluster, TerminalFrame, TerminalLine};
use tracking::{Identities, TrackingHandler};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::color::{Colors, COUNT};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor, Rgb, Timeout};

const MAX_COLUMNS: usize = 4096;
const MAX_ROWS: usize = 1024;
const MAX_HISTORY: usize = 10_000;

#[derive(Clone, Copy)]
struct Size(usize, usize);

impl Dimensions for Size {
    fn columns(&self) -> usize {
        self.0
    }
    fn screen_lines(&self) -> usize {
        self.1
    }
    fn total_lines(&self) -> usize {
        self.1
    }
}

#[derive(Clone, Default)]
struct Events(Arc<Mutex<Vec<Event>>>);

impl EventListener for Events {
    fn send_event(&self, event: Event) {
        self.0.lock().unwrap().push(event);
    }
}

#[derive(Default)]
struct DisplayCache {
    order: Vec<u32>,
}

pub struct TerminalCore {
    term: Term<Events>,
    parser: Processor,
    events: Events,
    main: DisplayCache,
    alternate: DisplayCache,
    identities: Identities,
    palette: Vec<Option<Rgb>>,
    pending: bool,
    title: Option<String>,
    bell: bool,
}

impl TerminalCore {
    pub fn new(columns: u32, rows: u32, history: u32) -> Self {
        let events = Events::default();
        let size = size(columns, rows);
        let config = Config {
            scrolling_history: (history as usize).min(MAX_HISTORY),
            ..Config::default()
        };
        Self {
            term: Term::new(config, &size, events.clone()),
            parser: Processor::new(),
            events,
            main: DisplayCache::default(),
            alternate: DisplayCache::default(),
            identities: Identities::new(size.1, (history as usize).min(MAX_HISTORY)),
            palette: Vec::new(),
            pending: true,
            title: None,
            bell: false,
        }
    }

    pub fn resize(&mut self, columns: u32, rows: u32) {
        let size = size(columns, rows);
        if self.term.columns() == size.0 && self.term.screen_lines() == size.1 {
            return;
        }
        self.identities.record_cursor(&self.term);
        if self.term.columns() == size.0 {
            self.identities.resize_height(size.1);
        } else {
            self.identities.resize(size.1);
        }
        self.term.resize(size);
        self.identities.record_cursor(&self.term);
        self.pending = true;
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut handler = TrackingHandler::new(&mut self.term, &mut self.identities);
        self.parser.advance(&mut handler, bytes);
        self.pending = true;
        self.drain_events()
    }

    pub fn pending(&self) -> bool {
        self.pending || self.parser.sync_bytes_count() != 0
    }

    /// Timed-out synchronized updates must complete even if the peer goes quiet.
    pub fn expire_sync(&mut self) -> Vec<u8> {
        if self.parser.sync_bytes_count() != 0 && !self.parser.sync_timeout().pending_timeout() {
            let mut handler = TrackingHandler::new(&mut self.term, &mut self.identities);
            self.parser.stop_sync(&mut handler);
            self.pending = true;
        }
        self.drain_events()
    }

    pub fn finish(&mut self) -> Vec<u8> {
        let mut handler = TrackingHandler::new(&mut self.term, &mut self.identities);
        self.parser.stop_sync(&mut handler);
        self.pending = true;
        self.drain_events()
    }

    fn drain_events(&mut self) -> Vec<u8> {
        let events = std::mem::take(&mut *self.events.0.lock().unwrap());
        let mut replies = Vec::new();
        for event in events {
            match event {
                Event::PtyWrite(text) => replies.extend_from_slice(text.as_bytes()),
                Event::Title(title) => self.title = Some(title),
                Event::ResetTitle => self.title = Some(String::new()),
                Event::Bell => self.bell = true,
                Event::ColorRequest(index, formatter) => {
                    let color = self.term.colors()[index].unwrap_or_else(|| default_color(index));
                    replies.extend_from_slice(formatter(color).as_bytes());
                }
                Event::TextAreaSizeRequest(formatter) => {
                    replies.extend_from_slice(
                        formatter(WindowSize {
                            num_lines: self.term.screen_lines() as u16,
                            num_cols: self.term.columns() as u16,
                            cell_width: 0,
                            cell_height: 0,
                        })
                        .as_bytes(),
                    );
                }
                // Remote clipboard reads/writes remain disabled. The UI owns the
                // clipboard and does not grant OSC 52 access to remote programs.
                _ => {}
            }
        }
        replies
    }

    pub fn frame(&mut self) -> Option<TerminalFrame> {
        if !self.pending || self.parser.sync_timeout().pending_timeout() {
            return None;
        }
        let alternate = self.term.mode().contains(TermMode::ALT_SCREEN);
        let palette: Vec<_> = (0..COUNT).map(|i| self.term.colors()[i]).collect();
        let palette_changed = palette != self.palette;
        if palette_changed {
            // An inactive buffer must repaint too when it next becomes active.
            self.identities.damage_all();
            self.palette = palette;
        }
        let cache = if alternate {
            &mut self.alternate
        } else {
            &mut self.main
        };
        let grid = self.term.grid();
        self.identities.ensure(alternate, grid.total_lines());
        let metadata = self.identities.screen_mut(alternate);
        let history = grid.history_size();
        let mut order = Vec::with_capacity(grid.total_lines());
        let mut lines = Vec::new();
        let mut wrapped = false;
        for (meta, index) in metadata
            .rows
            .iter_mut()
            .zip(-(history as i32)..grid.screen_lines() as i32)
        {
            let row = &grid[Line(index)];
            order.push(meta.id);
            if meta.dirty || meta.wrapped != wrapped {
                let mut cells = Vec::with_capacity(grid.columns() * 4);
                let mut clusters = Vec::new();
                // Do not export padding as text; retain backgrounds/attributes.
                let text_end = row
                    .into_iter()
                    .rposition(|c| c.c != ' ' || c.zerowidth().is_some_and(|z| !z.is_empty()))
                    .map_or(0, |i| i + 1);
                for (column, cell) in row.into_iter().enumerate() {
                    encode_cell(cell, column < text_end, self.term.colors(), &mut cells);
                    if let Some(extra) = cell.zerowidth().filter(|extra| !extra.is_empty()) {
                        let text: String = std::iter::once(cell.c)
                            .chain(extra.iter().copied())
                            .collect();
                        clusters.push(TerminalCluster {
                            column: column as u32,
                            text,
                        });
                    }
                }
                lines.push(TerminalLine {
                    id: meta.id,
                    wrapped,
                    cells,
                    clusters,
                });
                meta.dirty = false;
                meta.wrapped = wrapped;
            }
            wrapped = row[Column(grid.columns() - 1)]
                .flags
                .contains(Flags::WRAPLINE);
        }
        let trim_front = order
            .first()
            .and_then(|id| cache.order.iter().position(|old| old == id))
            .unwrap_or(0);
        let keep_rows = cache.order[trim_front..]
            .iter()
            .zip(&order)
            .take_while(|(a, b)| a == b)
            .count();
        let append_rows = order[keep_rows..].to_vec();
        cache.order = order;
        self.pending = false;
        let cursor = &grid.cursor.point;
        Some(TerminalFrame {
            columns: grid.columns() as u32,
            rows: grid.screen_lines() as u32,
            alternate,
            cursor_x: cursor.column.0 as u32,
            cursor_y: cursor.line.0.max(0) as u32,
            modes: self.term.mode().bits(),
            cursor_blink: self.term.cursor_style().blinking,
            trim_front: trim_front as u32,
            keep_rows: keep_rows as u32,
            append_rows,
            lines,
            title: self.title.take(),
            bell: std::mem::take(&mut self.bell),
        })
    }
}

fn size(columns: u32, rows: u32) -> Size {
    Size(
        (columns as usize).clamp(2, MAX_COLUMNS),
        (rows as usize).clamp(1, MAX_ROWS),
    )
}

fn encode_cell(cell: &Cell, has_text: bool, colors: &Colors, output: &mut Vec<u32>) {
    let f = cell.flags;
    let mut attrs = 0;
    for (flag, bit) in [
        (Flags::BOLD, 0),
        (Flags::DIM, 1),
        (Flags::ITALIC, 2),
        (Flags::ALL_UNDERLINES, 3),
        (Flags::INVERSE, 5),
        (Flags::HIDDEN, 6),
        (Flags::STRIKEOUT, 7),
    ] {
        if f.intersects(flag) {
            attrs |= 1 << bit;
        }
    }
    let spacer = f.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
    let width = if spacer {
        0
    } else if f.contains(Flags::WIDE_CHAR) {
        2
    } else {
        1
    };
    let codepoint = if has_text && !spacer {
        cell.c as u32
    } else {
        0
    };
    output.extend_from_slice(&[
        encode_color(cell.fg, colors),
        encode_color(cell.bg, colors),
        attrs,
        codepoint | (width << 22),
    ]);
}

fn encode_color(color: Color, colors: &Colors) -> u32 {
    let rgb = match color {
        Color::Spec(rgb) => Some(rgb),
        Color::Indexed(i) => colors[i as usize],
        Color::Named(i) => colors[i],
    };
    if let Some(Rgb { r, g, b }) = rgb {
        return (3 << 25) | ((r as u32) << 16) | ((g as u32) << 8) | b as u32;
    }
    match color {
        Color::Indexed(index) => (2 << 25) | index as u32,
        Color::Named(name) if (name as usize) < 16 => (1 << 25) | name as u32,
        _ => 0,
    }
}

fn default_color(index: usize) -> Rgb {
    let value = match index {
        0..=15 => [
            0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
            0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
        ][index],
        16..=231 => {
            let n = index - 16;
            let component = |v: usize| if v == 0 { 0 } else { 55 + v * 40 };
            (component(n / 36) << 16) | (component(n / 6 % 6) << 8) | component(n % 6)
        }
        232..=255 => (8 + (index - 232) * 10) * 0x010101,
        i if i == NamedColor::Background as usize => 0,
        _ => 0xcccccc,
    };
    Rgb {
        r: (value >> 16) as u8,
        g: (value >> 8) as u8,
        b: value as u8,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn text(line: &TerminalLine) -> String {
        line.cells
            .as_chunks::<4>()
            .0
            .iter()
            .filter_map(|c| char::from_u32(c[3] & 0x1fffff))
            .filter(|c| *c != '\0')
            .collect()
    }

    /// Shared native-generated frames exercise the real parser on Rust and the
    /// unchanged Flutter renderer/selection/IME on Dart without a remote host.
    #[test]
    fn flutter_render_fixture_matches_native_parser() {
        let mut core = TerminalCore::new(48, 12, 32);
        let mut frames = Vec::new();
        for n in 0..100 {
            core.feed(format!("row-{n:03} abcdefghijklmnop\r\n").as_bytes());
        }
        frames.push(core.frame().unwrap());
        core.feed(b"row-100 abcdefghijklmnop\r\n");
        frames.push(core.frame().unwrap());
        core.feed("\x1b[?1049h\x1b[?2004h\x1b[?1h\x1b[?1006h\x1b[?1002h\x1b[2J\x1b[H\x1b[38;2;18;52;86m中e\u{301} 🙂".as_bytes());
        frames.push(core.frame().unwrap());
        core.feed(b"\x1b[?1049l\x1b[?2004l\x1b[?1l\x1b[?1006l\x1b[?1002l");
        frames.push(core.frame().unwrap());
        core.resize(32, 10);
        frames.push(core.frame().unwrap());
        core.feed(b"\x1b[?1049h\x1b[2J\x1b[HA\r\nB\r\nC");
        frames.push(core.frame().unwrap());
        core.feed(b"\x1b[H\x1b[T");
        frames.push(core.frame().unwrap());
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../test/fixtures/native_terminal_frames.json");
        let actual = serde_json::to_value(&frames).unwrap();
        if std::env::var_os("PAGASHELL_UPDATE_TERMINAL_FIXTURE").is_some() {
            std::fs::write(&fixture, serde_json::to_string(&actual).unwrap() + "\n").unwrap();
        }
        let expected: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(fixture).unwrap()).unwrap();
        assert!(
            actual == expected,
            "Native frame fixture changed; regenerate it with PAGASHELL_UPDATE_TERMINAL_FIXTURE=1"
        );
    }

    #[test]
    fn split_utf8_ansi_styles_combining_and_device_replies() {
        let mut core = TerminalCore::new(20, 3, 100);
        let bytes = "\x1b[31;1m中e\u{301}\x1b[0m".as_bytes();
        for byte in bytes {
            core.feed(&[*byte]);
        }
        let frame = core.frame().unwrap();
        let line = &frame.lines[0];
        assert_eq!(text(line), "中e");
        assert_eq!(line.cells[0], (1 << 25) | 1);
        assert_eq!(line.cells[2] & 1, 1);
        assert_eq!(line.cells[3] >> 22, 2);
        assert_eq!(line.cells[7] & 0x1fffff, 0);
        assert_eq!(line.clusters[0].column, 2);
        assert_eq!(line.clusters[0].text, "e\u{301}");
        assert_eq!(core.feed(b"\x1b[6n"), b"\x1b[1;4R");
        assert!(!core.feed(b"\x1b[c").is_empty());
    }

    #[test]
    fn incremental_rows_preserve_history_identity_and_bound_scrollback() {
        let mut core = TerminalCore::new(16, 3, 3);
        core.feed(b"zero\r\none\r\ntwo");
        let first = core.frame().unwrap();
        let zero = first.append_rows[0];
        let one = first.append_rows[1];
        core.feed(b"\r\nthree");
        let second = core.frame().unwrap();
        assert_eq!(second.trim_front, 0);
        assert_eq!(second.keep_rows, 3);
        assert_eq!(second.append_rows.len(), 1);
        assert!(!second
            .lines
            .iter()
            .any(|line| line.id == zero || line.id == one));
        // More than an entire ring of output between frames must not recycle IDs.
        let old_ids: HashSet<_> = core.main.order.iter().copied().collect();
        for n in 0..30 {
            core.feed(format!("\r\nline-{n}").as_bytes());
        }
        let third = core.frame().unwrap();
        assert_eq!(core.main.order.len(), 6);
        assert!(core.main.order.iter().all(|id| !old_ids.contains(id)));
        assert!(third.lines.iter().any(|line| text(line) == "line-29"));
        core.feed(b"!");
        let fourth = core.frame().unwrap();
        assert_eq!(fourth.lines.len(), 1);
        assert_eq!(fourth.keep_rows, 6);
        assert!(fourth.append_rows.is_empty());
    }

    #[test]
    fn scroll_region_row_swaps_move_identity_with_contents() {
        let mut core = TerminalCore::new(8, 3, 5);
        core.feed(b"A\r\nB\r\nC");
        core.frame();
        let ids = core.main.order.clone();
        core.feed(b"\x1b[H\x1b[T");
        let frame = core.frame().unwrap();
        assert_eq!(core.main.order[1], ids[0]);
        assert_eq!(core.main.order[2], ids[1]);
        assert!(!core.main.order.contains(&ids[2]));
        assert_eq!(frame.append_rows[1..], ids[..2]);
        assert_eq!(core.term.grid()[Line(1)][Column(0)].c, 'A');
        assert_eq!(core.term.grid()[Line(2)][Column(0)].c, 'B');
    }

    #[test]
    fn alternate_screen_modes_resize_reflow_and_title() {
        let mut core = TerminalCore::new(8, 3, 100);
        core.feed(b"abcdefghijkl");
        let main = core.frame().unwrap();
        assert!(main.lines[1].wrapped);
        let ids = core.main.order.clone();
        core.feed(b"\x1b[?1049h\x1b[?2004h\x1b[?1h\x1b[?1006h\x1b[?1002h\x1b[2J\x1b[Hvim");
        let alt = core.frame().unwrap();
        assert!(alt.alternate);
        assert_eq!(core.alternate.order.len(), 3);
        assert_ne!(alt.modes & TermMode::BRACKETED_PASTE.bits(), 0);
        assert_ne!(alt.modes & TermMode::APP_CURSOR.bits(), 0);
        assert_ne!(alt.modes & TermMode::SGR_MOUSE.bits(), 0);
        assert_ne!(alt.modes & TermMode::MOUSE_DRAG.bits(), 0);
        core.feed(b"\x1b[?1049l\x1b]2;title\x07\x07");
        let restored = core.frame().unwrap();
        assert!(!restored.alternate);
        assert_eq!(core.main.order, ids);
        assert_eq!(restored.title.as_deref(), Some("title"));
        assert!(restored.bell);
        core.resize(16, 4);
        let resized = core.frame().unwrap();
        assert_eq!((resized.columns, resized.rows), (16, 4));
        assert!(resized
            .lines
            .iter()
            .any(|line| text(line).starts_with("abcdefghijkl")));
    }

    #[test]
    fn synchronized_updates_wait_for_end_or_timeout_and_flush_on_exit() {
        let mut core = TerminalCore::new(10, 2, 10);
        core.frame();
        core.feed(b"\x1b[?2026hpartial");
        assert!(core.frame().is_none());
        core.feed(b"\x1b[?2026l");
        assert!(core
            .frame()
            .unwrap()
            .lines
            .iter()
            .any(|line| text(line) == "partial"));
        core.feed(b"\x1b[?2026h!");
        assert!(core.frame().is_none());
        core.finish();
        assert!(core
            .frame()
            .unwrap()
            .lines
            .iter()
            .any(|line| text(line) == "partial!"));
    }

    #[test]
    fn palette_changes_invalidate_existing_rows_and_ris_clears_stale_ids() {
        let mut core = TerminalCore::new(12, 3, 10);
        core.feed(b"\x1b[31mred");
        core.frame();
        core.feed(b"\x1b]4;1;rgb:12/34/56\x07");
        let palette = core.frame().unwrap();
        assert_eq!(palette.lines[0].cells[0], (3 << 25) | 0x123456);
        let old_ids: HashSet<_> = core.main.order.iter().copied().collect();
        core.feed(b"\x1bc");
        core.frame();
        assert!(core.main.order.iter().all(|id| !old_ids.contains(id)));
    }
}
