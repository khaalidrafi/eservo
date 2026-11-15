//! Engine thread + request/reply plumbing.
//!
//! Every Elisp-visible op is a synchronous Call message to the engine
//! thread (the blocking pattern of the reference embedder,
//! konippi/servo-fetch): the thread alone owns the servo instance --
//! Emacs never touches engine state concurrently -- and servo's
//! EventLoopWaker wakeups arrive as Wake messages on the same channel,
//! so `spin_event_loop` runs on the engine thread, exactly where the
//! embedding contract wants it.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread::JoinHandle;

/// One backend op, 1:1 with the `eservo-embedded-module-*' primitives
/// eservo-embedded.el maps onto the eservo op set.
pub enum ReqOp {
    Boot {
        width: u32,
        height: u32,
        resources: String,
        user_agent: String,
    },
    AliveP,
    Goto(String),
    Url,
    Snapshot,
    Fill {
        selector: String,
        text: String,
    },
    Click(String),
    Keys(String),
    Extract(String),
    Evaluate(String),
    WaitSelector {
        selector: String,
        timeout: u64,
    },
    Screenshot(String),
    Resize {
        width: u32,
        height: u32,
    },
}

pub enum Reply {
    Bool(bool),
    Str(String),
    Unit,
}

pub enum Msg {
    /// Request/reply: run the op, answer on the channel.
    Call(ReqOp, Sender<Result<Reply, String>>),
    /// servo's EventLoopWaker fired: an internal servo thread needs the
    /// event loop spun.
    Wake,
    /// Drop the engine and end the thread.
    Shutdown,
}

pub struct EngineHandle {
    tx: Sender<Msg>,
    join: Option<JoinHandle<()>>,
}

impl EngineHandle {
    /// Run one op to completion.  Blocks until the engine thread answers.
    pub fn call(&self, op: ReqOp) -> Result<Reply, String> {
        let (tx, rx) = channel();
        self.tx
            .send(Msg::Call(op, tx))
            .map_err(|_| "eservo: engine thread is gone".to_string())?;
        match rx.recv() {
            Ok(reply) => reply,
            Err(_) => Err("eservo: engine thread died answering the call".into()),
        }
    }

    pub fn shutdown(&mut self) {
        let _ = self.tx.send(Msg::Shutdown);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for EngineHandle {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Boot the engine thread.  The thread body is feature-gated: with the
/// `servo` feature it runs the real embedded engine (servo_glue.rs);
/// without it a stub that answers every op with the not-linked error --
/// which is what the fast CI lane loads into stock Emacs to prove the
/// module ABI with zero dependencies.
pub fn boot() -> EngineHandle {
    let (tx, rx) = channel::<Msg>();
    let tx_wake = tx.clone();
    let join = std::thread::Builder::new()
        .name("eservo-engine".into())
        .spawn(move || engine_main(rx, tx_wake))
        .expect("eservo: cannot spawn the engine thread");
    EngineHandle {
        tx,
        join: Some(join),
    }
}

#[cfg(not(feature = "servo"))]
fn engine_main(rx: Receiver<Msg>, _tx_wake: Sender<Msg>) {
    stub_main(rx);
}

#[cfg(feature = "servo")]
fn engine_main(rx: Receiver<Msg>, tx_wake: Sender<Msg>) {
    crate::servo_glue::engine_main(rx, tx_wake);
}

/// The zero-dependency engine: proves the ABI without servo linked.
#[cfg(not(feature = "servo"))]
fn stub_main(rx: Receiver<Msg>) {
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Call(op, reply) => {
                let _ = reply.send(match op {
                    // Not booted -- and it never can be in this build.
                    ReqOp::AliveP => Ok(Reply::Bool(false)),
                    _ => Err(
                        "eservo: this libeservo was built WITHOUT the servo \
                         engine feature; rebuild with \
                         `cargo build --release --features servo' \
                         (docs/EMBEDDED-SERVO.org, build lanes)"
                            .to_string(),
                    ),
                });
            }
            // No engine, nothing to wake.
            Msg::Wake => {}
            Msg::Shutdown => break,
        }
    }
}
