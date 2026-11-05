//! Row identity is owned by this module, never by upstream row layout/addresses.
//!
//! Observe VTE's public semantic callbacks and forward every callback to the
//! official Term. Only row order/lifetime is mirrored; parsing, cell contents,
//! cursor movement and reflow remain entirely upstream-owned.

use std::collections::VecDeque;
use std::ops::Range;

use alacritty_terminal::grid::{Dimensions, GridCell};
use alacritty_terminal::index::Line;
use alacritty_terminal::term::{Term, TermMode};
use alacritty_terminal::vte::ansi::{self, *};
use unicode_width::UnicodeWidthChar;

use super::Events;

pub(crate) struct RowMeta {
    pub id: u32,
    pub dirty: bool,
    pub wrapped: bool,
}

pub(crate) struct ScreenMeta {
    pub rows: VecDeque<RowMeta>,
    height: usize,
    history: usize,
    cursor: usize,
}

pub(crate) struct Identities {
    main: ScreenMeta,
    alt: ScreenMeta,
    next_id: u32,
    region: Range<usize>,
}

impl Identities {
    pub fn new(height: usize, history: usize) -> Self {
        let mut ids = Self {
            main: ScreenMeta {
                rows: VecDeque::new(),
                height,
                history,
                cursor: 0,
            },
            alt: ScreenMeta {
                rows: VecDeque::new(),
                height,
                history: 0,
                cursor: 0,
            },
            next_id: 1,
            region: 0..height,
        };
        ids.ensure(false, height);
        ids.ensure(true, height);
        ids
    }

    fn allocate(&mut self) -> RowMeta {
        let id = self.next_id;
        self.next_id = id.checked_add(1).expect("terminal row ID exhausted");
        RowMeta {
            id,
            dirty: true,
            wrapped: false,
        }
    }

    pub fn screen_mut(&mut self, alternate: bool) -> &mut ScreenMeta {
        if alternate {
            &mut self.alt
        } else {
            &mut self.main
        }
    }

    pub fn ensure(&mut self, alternate: bool, total: usize) {
        if self.screen_mut(alternate).rows.len() != total {
            // Width reflow is an explicit identity boundary. No content/hash
            // matching: equal text does not imply the same logical line.
            let rows = (0..total).map(|_| self.allocate()).collect();
            self.screen_mut(alternate).rows = rows;
        }
    }

    pub fn resize(&mut self, height: usize) {
        self.main.height = height;
        self.alt.height = height;
        self.main.rows.clear();
        self.alt.rows.clear();
        self.region = 0..height;
    }

    /// Height-only resize keeps rows intact. Mirror the public grid's vertical
    /// movement without inspecting private row storage or matching cell text.
    pub fn resize_height(&mut self, height: usize) {
        for alternate in [false, true] {
            let screen = self.screen_mut(alternate);
            let old_height = screen.height;
            if screen.rows.is_empty() {
                screen.height = height;
                continue;
            }
            if height > old_height {
                let history = screen.rows.len() - old_height;
                screen.cursor += (height - old_height).min(history);
                let added = (height - old_height).saturating_sub(history);
                let rows: Vec<_> = (0..added).map(|_| self.allocate()).collect();
                self.screen_mut(alternate).rows.extend(rows);
            } else {
                let scroll = (screen.cursor + 1).saturating_sub(height);
                self.scroll(alternate, 0..old_height, scroll, true);
                let screen = self.screen_mut(alternate);
                screen
                    .rows
                    .truncate(screen.rows.len() - (old_height - height));
            }
            let screen = self.screen_mut(alternate);
            screen.height = height;
            screen.cursor = screen.cursor.min(height - 1);
        }
        self.region = 0..height;
    }

    pub fn record_cursor(&mut self, term: &Term<Events>) {
        self.screen_mut(term.mode().contains(TermMode::ALT_SCREEN))
            .cursor = term.grid().cursor.point.line.0.max(0) as usize;
    }

    pub fn damage_all(&mut self) {
        for row in self.main.rows.iter_mut().chain(&mut self.alt.rows) {
            row.dirty = true;
        }
    }

    fn reset_rows(&mut self, alternate: bool, range: Range<usize>) {
        let height = self.screen_mut(alternate).height;
        let start = range.start.min(height);
        let end = range.end.min(height);
        let replacements: Vec<_> = (start..end).map(|_| self.allocate()).collect();
        let screen = self.screen_mut(alternate);
        let history = screen.rows.len().saturating_sub(height);
        for (index, row) in (start..end).zip(replacements) {
            screen.rows[history + index] = row;
        }
    }

    fn scroll(&mut self, alternate: bool, range: Range<usize>, count: usize, up: bool) {
        let count = count.min(range.end.saturating_sub(range.start));
        if count == 0 {
            return;
        }
        let replacements: Vec<_> = (0..count).map(|_| self.allocate()).collect();
        let screen = self.screen_mut(alternate);
        let history = screen.rows.len() - screen.height;
        if up && range.start == 0 {
            // Keep old top rows as history, including when a partial region
            // begins at row zero. Rows below the region stay on screen.
            for (offset, row) in replacements.into_iter().enumerate() {
                screen.rows.insert(history + range.end + offset, row);
            }
            while screen.rows.len() > screen.height + screen.history {
                screen.rows.pop_front();
            }
        } else if up {
            for _ in 0..count {
                screen.rows.remove(history + range.start);
            }
            for (offset, row) in replacements.into_iter().enumerate() {
                screen
                    .rows
                    .insert(history + range.end - count + offset, row);
            }
        } else {
            for _ in 0..count {
                screen.rows.remove(history + range.end - count);
            }
            for (offset, row) in replacements.into_iter().enumerate() {
                screen.rows.insert(history + range.start + offset, row);
            }
        }
    }
}

pub(crate) struct TrackingHandler<'a> {
    term: &'a mut Term<Events>,
    ids: &'a mut Identities,
}

macro_rules! forward {
    ($($name:ident($($arg:ident: $ty:ty),*);)*) => {$ (
        fn $name(&mut self, $($arg: $ty),*) {
            self.touch_cursor();
            self.term.$name($($arg),*);
            self.touch_cursor();
        }
    )*};
}

impl<'a> TrackingHandler<'a> {
    pub fn new(term: &'a mut Term<Events>, ids: &'a mut Identities) -> Self {
        let alternate = term.mode().contains(TermMode::ALT_SCREEN);
        ids.ensure(alternate, term.total_lines());
        Self { term, ids }
    }

    fn alternate(&self) -> bool {
        self.term.mode().contains(TermMode::ALT_SCREEN)
    }

    fn touch_cursor(&mut self) {
        self.ids.record_cursor(self.term);
        let alternate = self.alternate();
        let line = self.term.grid().cursor.point.line.0.max(0) as usize;
        let screen = self.ids.screen_mut(alternate);
        let history = screen.rows.len().saturating_sub(screen.height);
        if let Some(row) = screen.rows.get_mut(history + line) {
            row.dirty = true;
        }
    }

    fn damage_viewport(&mut self) {
        let alternate = self.alternate();
        let screen = self.ids.screen_mut(alternate);
        let history = screen.rows.len() - screen.height;
        for row in screen.rows.iter_mut().skip(history) {
            row.dirty = true;
        }
    }

    fn scroll(&mut self, origin: usize, count: usize, up: bool) {
        let range = origin..self.ids.region.end;
        let count = count.min(self.ids.region.end - self.ids.region.start);
        self.ids.scroll(self.alternate(), range, count, up);
    }

    fn linefeed_identity(&mut self) {
        let next = self.term.grid().cursor.point.line.0 + 1;
        if next == self.ids.region.end as i32 {
            self.scroll(self.ids.region.start, 1, true);
        }
    }
}

impl Handler for TrackingHandler<'_> {
    fn input(&mut self, c: char) {
        self.touch_cursor();
        let grid = self.term.grid();
        let width = c.width().unwrap_or(0);
        let wraps = width > 0
            && self.term.mode().contains(TermMode::LINE_WRAP)
            && (grid.cursor.input_needs_wrap
                || (width == 2 && grid.cursor.point.column.0 + 1 >= grid.columns()));
        if wraps {
            self.linefeed_identity();
        }
        self.term.input(c);
        self.touch_cursor();
    }

    fn linefeed(&mut self) {
        self.linefeed_identity();
        self.term.linefeed();
    }

    fn newline(&mut self) {
        self.linefeed_identity();
        self.term.newline();
    }

    fn scroll_up(&mut self, count: usize) {
        self.scroll(self.ids.region.start, count, true);
        self.term.scroll_up(count);
    }

    fn scroll_down(&mut self, count: usize) {
        self.scroll(self.ids.region.start, count, false);
        self.term.scroll_down(count);
    }

    fn insert_blank_lines(&mut self, count: usize) {
        let line = self.term.grid().cursor.point.line.0 as usize;
        if self.ids.region.contains(&line) {
            self.scroll(line, count, false);
        }
        self.term.insert_blank_lines(count);
    }

    fn delete_lines(&mut self, count: usize) {
        let line = self.term.grid().cursor.point.line.0 as usize;
        if self.ids.region.contains(&line) {
            self.scroll(line, count, true);
        }
        self.term.delete_lines(count);
    }

    fn reverse_index(&mut self) {
        if self.term.grid().cursor.point.line.0 == self.ids.region.start as i32 {
            self.scroll(self.ids.region.start, 1, false);
        }
        self.term.reverse_index();
    }

    fn clear_screen(&mut self, mode: ClearMode) {
        let alternate = self.alternate();
        let height = self.term.screen_lines();
        let cursor = self.term.grid().cursor.point.line.0 as usize;
        match mode {
            ClearMode::All => {
                if !alternate {
                    let grid = self.term.grid();
                    let used = (0..height)
                        .rev()
                        .find(|&line| {
                            grid[Line(line as i32)]
                                .into_iter()
                                .any(|cell| !cell.is_empty())
                        })
                        .map_or(0, |line| line + 1);
                    self.ids.scroll(false, 0..height, used, true);
                }
                self.ids.reset_rows(alternate, 0..height);
            }
            ClearMode::Above if cursor > 1 => self.ids.reset_rows(alternate, 0..cursor),
            ClearMode::Below => self.ids.reset_rows(alternate, cursor + 1..height),
            ClearMode::Saved => {
                let screen = self.ids.screen_mut(alternate);
                while screen.rows.len() > height {
                    screen.rows.pop_front();
                }
            }
            _ => (),
        }
        self.term.clear_screen(mode);
        self.damage_viewport();
    }

    fn reset_state(&mut self) {
        self.term.reset_state();
        let height = self.term.screen_lines();
        self.ids.resize(height);
        self.ids.ensure(false, height);
        self.ids.ensure(true, height);
    }

    fn set_scrolling_region(&mut self, top: usize, bottom: Option<usize>) {
        let bottom = bottom.unwrap_or_else(|| self.term.screen_lines());
        if top < bottom {
            let height = self.term.screen_lines();
            self.ids.region = top.saturating_sub(1).min(height)..bottom.min(height);
        }
        self.term.set_scrolling_region(top, Some(bottom));
    }

    fn set_private_mode(&mut self, mode: PrivateMode) {
        self.ids.record_cursor(self.term);
        let alternate = self.alternate();
        self.term.set_private_mode(mode);
        self.ids.record_cursor(self.term);
        if alternate != self.alternate() {
            self.ids.ensure(true, self.term.total_lines());
            self.ids.reset_rows(true, 0..self.term.screen_lines());
        }
        if mode == PrivateMode::Named(NamedPrivateMode::ColumnMode) {
            let height = self.term.screen_lines();
            self.ids.region = 0..height;
            self.ids.reset_rows(self.alternate(), 0..height);
        }
    }

    fn unset_private_mode(&mut self, mode: PrivateMode) {
        self.ids.record_cursor(self.term);
        self.term.unset_private_mode(mode);
        self.ids.record_cursor(self.term);
        self.ids.ensure(self.alternate(), self.term.total_lines());
        if mode == PrivateMode::Named(NamedPrivateMode::ColumnMode) {
            let height = self.term.screen_lines();
            self.ids.region = 0..height;
            self.ids.reset_rows(self.alternate(), 0..height);
        }
    }

    fn decaln(&mut self) {
        self.term.decaln();
        self.damage_viewport();
    }

    // Explicit forwarding keeps terminal replies, charsets, mouse/keyboard
    // modes and future supported OSC behavior on the official implementation.
    forward! {
        set_title(title: Option<String>);
        set_cursor_style(style: Option<CursorStyle>);
        set_cursor_shape(shape: CursorShape);
        goto(line: i32, col: usize);
        goto_line(line: i32);
        goto_col(col: usize);
        insert_blank(count: usize);
        move_up(count: usize);
        move_down(count: usize);
        identify_terminal(intermediate: Option<char>);
        device_status(status: usize);
        move_forward(count: usize);
        move_backward(count: usize);
        move_down_and_cr(count: usize);
        move_up_and_cr(count: usize);
        put_tab(count: u16);
        backspace();
        carriage_return();
        bell();
        substitute();
        set_horizontal_tabstop();
        erase_chars(count: usize);
        delete_chars(count: usize);
        move_backward_tabs(count: u16);
        move_forward_tabs(count: u16);
        save_cursor_position();
        restore_cursor_position();
        clear_line(mode: LineClearMode);
        clear_tabs(mode: TabulationClearMode);
        set_tabs(interval: u16);
        terminal_attribute(attr: Attr);
        set_mode(mode: Mode);
        unset_mode(mode: Mode);
        report_mode(mode: Mode);
        report_private_mode(mode: PrivateMode);
        set_keypad_application_mode();
        unset_keypad_application_mode();
        set_active_charset(index: CharsetIndex);
        configure_charset(index: CharsetIndex, charset: StandardCharset);
        set_color(index: usize, color: Rgb);
        dynamic_color_sequence(prefix: String, index: usize, terminator: &str);
        reset_color(index: usize);
        clipboard_store(clipboard: u8, data: &[u8]);
        clipboard_load(clipboard: u8, terminator: &str);
        push_title();
        pop_title();
        text_area_size_pixels();
        text_area_size_chars();
        set_hyperlink(link: Option<Hyperlink>);
        set_mouse_cursor_icon(icon: ansi::cursor_icon::CursorIcon);
        report_keyboard_mode();
        push_keyboard_mode(mode: KeyboardModes);
        pop_keyboard_modes(count: u16);
        set_keyboard_mode(mode: KeyboardModes, behavior: KeyboardModesApplyBehavior);
        set_modify_other_keys(mode: ModifyOtherKeys);
        report_modify_other_keys();
        set_scp(path: ScpCharPath, mode: ScpUpdateMode);
    }
}
