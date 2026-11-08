//! Optional timers of the native core (bench/prof): off unless
//! `UxmlNative.prof_enable(true)`. Each slot sums nanoseconds and calls.
use std::cell::{Cell, RefCell};
use std::time::Instant;

thread_local! {
    static ON: Cell<bool> = const { Cell::new(false) };
    static SLOTS: RefCell<Vec<(&'static str, u64, u64)>> = const { RefCell::new(Vec::new()) };
}

pub fn enable(on: bool) {
    ON.with(|o| o.set(on));
}

#[inline]
pub fn on() -> bool {
    ON.with(|o| o.get())
}

pub struct Scope {
    name: &'static str,
    t: Option<Instant>,
}

#[inline]
pub fn scope(name: &'static str) -> Scope {
    Scope { name, t: if on() { Some(Instant::now()) } else { None } }
}

impl Drop for Scope {
    fn drop(&mut self) {
        if let Some(t) = self.t {
            let ns = t.elapsed().as_nanos() as u64;
            SLOTS.with(|s| {
                let mut s = s.borrow_mut();
                if let Some(e) = s.iter_mut().find(|e| e.0 == self.name) {
                    e.1 += ns;
                    e.2 += 1;
                } else {
                    s.push((self.name, ns, 1));
                }
            });
        }
    }
}

pub fn take() -> Vec<(&'static str, u64, u64)> {
    SLOTS.with(|s| std::mem::take(&mut *s.borrow_mut()))
}
