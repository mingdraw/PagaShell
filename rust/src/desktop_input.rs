use ironrdp::pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp::pdu::input::mouse::{MousePdu, PointerFlags};

/// Track inputs accepted by the native session, independently of UI teardown.
pub(crate) struct HeldInputs {
    keys: Vec<(KeyboardFlags, u8)>,
    buttons: PointerFlags,
    x: u16,
    y: u16,
}

impl Default for HeldInputs {
    fn default() -> Self {
        Self {
            keys: Vec::new(),
            buttons: PointerFlags::empty(),
            x: 0,
            y: 0,
        }
    }
}

impl HeldInputs {
    pub fn record(&mut self, events: &[FastPathInputEvent]) {
        for event in events {
            match *event {
                FastPathInputEvent::KeyboardEvent(flags, code) => {
                    let key = (flags - KeyboardFlags::RELEASE, code);
                    if flags.contains(KeyboardFlags::RELEASE) {
                        self.keys.retain(|held| *held != key);
                    } else if !self.keys.contains(&key) {
                        self.keys.push(key);
                    }
                }
                FastPathInputEvent::MouseEvent(mouse) => {
                    self.x = mouse.x_position;
                    self.y = mouse.y_position;
                    let buttons = mouse.flags
                        & (PointerFlags::LEFT_BUTTON
                            | PointerFlags::RIGHT_BUTTON
                            | PointerFlags::MIDDLE_BUTTON_OR_WHEEL);
                    if mouse.flags.contains(PointerFlags::DOWN) {
                        self.buttons.insert(buttons);
                    } else {
                        self.buttons.remove(buttons);
                    }
                }
                _ => {}
            }
        }
    }

    pub fn releases(&self) -> Vec<FastPathInputEvent> {
        let mut events: Vec<_> = self
            .keys
            .iter()
            .rev()
            .map(|&(flags, code)| {
                FastPathInputEvent::KeyboardEvent(flags | KeyboardFlags::RELEASE, code)
            })
            .collect();
        for button in [
            PointerFlags::LEFT_BUTTON,
            PointerFlags::RIGHT_BUTTON,
            PointerFlags::MIDDLE_BUTTON_OR_WHEEL,
        ] {
            if self.buttons.contains(button) {
                events.push(FastPathInputEvent::MouseEvent(MousePdu {
                    flags: button,
                    number_of_wheel_rotation_units: 0,
                    x_position: self.x,
                    y_position: self.y,
                }));
            }
        }
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disconnect_releases_held_keys_and_buttons_after_ui_teardown() {
        let mut held = HeldInputs::default();
        held.record(&[
            FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x1d),
            FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x1d),
            FastPathInputEvent::KeyboardEvent(KeyboardFlags::EXTENDED, 0x1d),
            FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, 0x1d),
            FastPathInputEvent::MouseEvent(MousePdu {
                flags: PointerFlags::LEFT_BUTTON | PointerFlags::DOWN,
                number_of_wheel_rotation_units: 0,
                x_position: 10,
                y_position: 20,
            }),
            FastPathInputEvent::MouseEvent(MousePdu {
                flags: PointerFlags::MOVE,
                number_of_wheel_rotation_units: 0,
                x_position: 40,
                y_position: 50,
            }),
        ]);
        let releases = held.releases();
        assert_eq!(
            releases,
            vec![
                FastPathInputEvent::KeyboardEvent(
                    KeyboardFlags::EXTENDED | KeyboardFlags::RELEASE,
                    0x1d,
                ),
                FastPathInputEvent::MouseEvent(MousePdu {
                    flags: PointerFlags::LEFT_BUTTON,
                    number_of_wheel_rotation_units: 0,
                    x_position: 40,
                    y_position: 50,
                }),
            ]
        );
        held.record(&releases);
        assert!(held.releases().is_empty());
    }
}
