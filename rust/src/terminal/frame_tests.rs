//! Compare an incremental consumer with the official grid after each operation.

use std::collections::{HashMap, HashSet};

use super::*;

#[derive(Default)]
struct Screen {
    order: Vec<u32>,
    lines: HashMap<u32, TerminalLine>,
}

#[derive(Default)]
struct Mirror {
    main: Screen,
    alternate: Screen,
}

impl Mirror {
    fn check(&mut self, core: &mut TerminalCore, context: &str) {
        let frame = core.frame().expect(context);
        let screen = if frame.alternate {
            &mut self.alternate
        } else {
            &mut self.main
        };
        for line in frame.lines {
            screen.lines.insert(line.id, line);
        }
        screen.order.drain(..frame.trim_front as usize);
        screen.order.truncate(frame.keep_rows as usize);
        screen.order.extend(frame.append_rows);
        let alive: HashSet<_> = screen.order.iter().copied().collect();
        assert_eq!(alive.len(), screen.order.len(), "duplicate IDs: {context}");
        screen.lines.retain(|id, _| alive.contains(id));

        let grid = core.term.grid();
        assert_eq!(screen.order.len(), grid.total_lines(), "{context}");
        assert_eq!(
            (frame.cursor_x, frame.cursor_y),
            (
                grid.cursor.point.column.0 as u32,
                grid.cursor.point.line.0 as u32
            ),
            "{context}"
        );
        let mut wrapped = false;
        for (position, index) in
            (-(grid.history_size() as i32)..grid.screen_lines() as i32).enumerate()
        {
            let row = &grid[Line(index)];
            let line = &screen.lines[&screen.order[position]];
            let end = row
                .into_iter()
                .rposition(|c| c.c != ' ' || c.zerowidth().is_some_and(|z| !z.is_empty()))
                .map_or(0, |i| i + 1);
            let mut expected = Vec::new();
            let mut clusters = Vec::new();
            for (column, cell) in row.into_iter().enumerate() {
                encode_cell(cell, column < end, core.term.colors(), &mut expected);
                if let Some(extra) = cell.zerowidth().filter(|extra| !extra.is_empty()) {
                    clusters.push((
                        column as u32,
                        std::iter::once(cell.c)
                            .chain(extra.iter().copied())
                            .collect::<String>(),
                    ));
                }
            }
            assert_eq!(line.cells, expected, "{context}, row {index}");
            assert_eq!(
                line.clusters
                    .iter()
                    .map(|c| (c.column, c.text.clone()))
                    .collect::<Vec<_>>(),
                clusters,
                "{context}, clusters {index}"
            );
            assert_eq!(line.wrapped, wrapped, "{context}, wrap {index}");
            wrapped = row[Column(grid.columns() - 1)]
                .flags
                .contains(Flags::WRAPLINE);
        }
    }
}

#[test]
fn incremental_mirror_matches_official_grid_for_screen_operations() {
    let mut core = TerminalCore::new(8, 5, 7);
    let mut mirror = Mirror::default();
    mirror.check(&mut core, "initial");
    for operation in [
        "A\r\nB\r\nC\r\nD\r\nE",
        "\x1b[1;4r\x1b[4;1H\nZ", // top region with fixed footer
        "\x1b[2;4r\x1b[2;1H\x1b[2S",
        "\x1b[2T\x1b[3;1H\x1b[4L",
        "\x1b[2M\x1bM",
        "\x1b[r\x1b[H1234567中e\u{301}🙂",
        "\x1b[?7l\x1b[5;8H中!\x1b[?7h",
        "\x1b[H\x1b[2@\x1b[P\x1b[3X",
        "\x1b[3;2H\x1b[1J",
        "\x1b[0J",
        "\x1b[2J",
        "\x1b[3J",
        "\x1b[?1049hALT\x1b[2J\x1b[Habc",
        "\x1b#8\x1b[?1049l",
        "\x1b]4;1;rgb:12/34/56\x07\x1b[31mred",
        "\x1b[?3h\x1b[?3l",
        "\x1bc",
    ] {
        core.feed(operation.as_bytes());
        mirror.check(&mut core, operation);
    }

    // Deterministic mixed operations, with several parser callbacks per frame.
    let mut state = 0xabc123_u32;
    for batch in 0..200 {
        for _ in 0..5 {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let row = state as usize % 5 + 1;
            let operation = match state >> 24 & 15 {
                0 => format!("\x1b[{row};2H中\u{301}"),
                1 => "\r\nrepeat".into(),
                2 => "\x1b[2S".into(),
                3 => "\x1b[T".into(),
                4 => format!("\x1b[{row};1H\x1b[2L"),
                5 => "\x1b[2M".into(),
                6 => "\x1b[1;4r".into(),
                7 => "\x1b[2;5r".into(),
                8 => "\x1b[r\x1b[2J".into(),
                9 => "\x1b[0J\x1b[1K".into(),
                10 => "\x1b[?1049h".into(),
                11 => "\x1b[?1049l".into(),
                12 => "\x1bM".into(),
                13 => "12345678🙂e\u{301}".into(),
                14 => "\x1b[2@\x1b[P".into(),
                _ => "\x1b[3J\x1b[1J".into(),
            };
            core.feed(operation.as_bytes());
        }
        mirror.check(&mut core, &format!("batch {batch}"));
    }
}

#[test]
fn identical_recycled_rows_never_reuse_old_identity() {
    let mut core = TerminalCore::new(8, 3, 3);
    let mut mirror = Mirror::default();
    core.feed(b"repeat\r\nrepeat\r\nrepeat");
    mirror.check(&mut core, "duplicates");
    let original: HashSet<_> = core.main.order.iter().copied().collect();
    for _ in 0..50 {
        core.feed(b"\r\nrepeat");
    }
    mirror.check(&mut core, "recycled");
    assert!(core.main.order.iter().all(|id| !original.contains(id)));
}

#[test]
fn height_resize_preserves_rows_in_both_buffers_and_width_reflow_invalidates_ids() {
    let mut core = TerminalCore::new(10, 4, 6);
    let mut mirror = Mirror::default();
    for n in 0..12 {
        core.feed(format!("row-{n}\r\n").as_bytes());
    }
    mirror.check(&mut core, "before grow");
    let original = core.main.order.clone();
    core.resize(10, 7);
    mirror.check(&mut core, "grow with history");
    assert_eq!(core.main.order, original);
    core.resize(10, 2);
    mirror.check(&mut core, "shrink with cursor at bottom");
    core.feed(b"\x1b[?1049hALT");
    mirror.check(&mut core, "enter alt");
    for height in [6, 3, 8, 1, 5] {
        core.resize(10, height);
        mirror.check(&mut core, "resize while main inactive");
    }
    core.feed(b"\x1b[?1049l");
    mirror.check(&mut core, "restore main after height changes");
    let before_reflow: HashSet<_> = core.main.order.iter().copied().collect();
    core.resize(5, 5);
    mirror.check(&mut core, "width reflow");
    assert!(core.main.order.iter().all(|id| !before_reflow.contains(id)));
    core.resize(5, 5);
    assert!(core.frame().is_none(), "same dimensions must be a no-op");
}
