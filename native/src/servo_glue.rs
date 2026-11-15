//! The real engine: servo embedded on the engine thread.
//!
//! Coded against servo's documented embedding surface: the Servo Book
//! embedding chapter (book.servo.org/embedding/overview.html) plus the
//! official minimal example in servo's own tree
//! (components/servo/examples/winit_minimal.rs on servo main, read
//! 2026-11-15) and the reference embedder konippi/servo-fetch.
//!
//! Calls we could NOT verify from documentation are marked `PIN:` --
//! they are the first things the `servo` CI lane (the compile pin)
//! checks.  Keep every pin edit local to the marked function so the
//! pin job never turns into an archaeology dig.

use std::rc::Rc;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use euclid::{Scale, Size2D};
use url::Url;

use servo::RenderingContext;
use servo::SoftwareRenderingContext;
use servo::{Servo, ServoBuilder, WebView, WebViewBuilder};
// Embedder-traits items are re-exported at the servo crate ROOT
// (verified against konippi/servo-fetch bridge.rs, 2026-11-15);
// the `servo::embedder_traits::` module path does not exist.
use servo::EventLoopWaker;

use crate::engine::{Msg, Reply, ReqOp};

/// How long `goto` waits for the page to produce a frame.
const LOAD_TIMEOUT: Duration = Duration::from_secs(30);

/// Page state shared with the delegate callbacks (which servo invokes on
/// its own threads -- hence the Mutex; contention is trivial).
#[derive(Default)]
struct PageState {
    inner: Mutex<PageStateInner>,
}

#[derive(Default)]
struct PageStateInner {
    /// Last URL handed to WebView::load.  PIN(servo-0.8): the real
    /// post-redirect URL arrives through a delegate notification we have
    /// not wired yet -- until then `url` reports what we navigated to.
    url: String,
    /// Count of notify_new_frame_ready callbacks: our load heuristic.
    frames: u64,
}

impl PageState {
    fn record_load(&self, url: &str) {
        self.inner.lock().unwrap().url = url.to_string();
    }
    fn current_url(&self) -> String {
        self.inner.lock().unwrap().url.clone()
    }
    fn frame_count(&self) -> u64 {
        self.inner.lock().unwrap().frames
    }
    fn record_frame(&self) {
        self.inner.lock().unwrap().frames += 1;
    }
}

/// EventLoopWaker over the engine channel: servo's internal threads wake
/// the engine thread, which answers by spinning the event loop.  Shape
/// verified against the official winit example.
struct ChannelWaker {
    tx: Sender<Msg>,
}

impl Clone for ChannelWaker {
    fn clone(&self) -> Self {
        Self {
            tx: self.tx.clone(),
        }
    }
}

impl EventLoopWaker for ChannelWaker {
    fn clone_box(&self) -> Box<dyn EventLoopWaker> {
        Box::new(self.clone())
    }
    fn wake(&self) {
        // Never block a servo thread on us: if the engine is mid-op the
        // wakeup queues and is drained right after.
        let _ = self.tx.send(Msg::Wake);
    }
}

/// The WebViewDelegate: the minimum an embedder must implement is
/// notify_new_frame_ready (the Servo Book embedding overview says so).
struct PageDelegate {
    state: Rc<PageState>,
}

impl servo::WebViewDelegate for PageDelegate {
    fn notify_new_frame_ready(&self, _webview: WebView) {
        self.state.record_frame();
    }
    // PIN(servo-0.8): the load-status surface.  servo's delegates also
    // notify URL changes and load start/end (servoshell consumes them);
    // wire those methods here when the pin compile reveals their exact
    // names.  Until then `goto` uses the new-frame heuristic below.
}

struct Engine {
    servo: Servo,
    ctx: Rc<SoftwareRenderingContext>,
    webview: WebView,
    state: Rc<PageState>,
}

pub fn engine_main(rx: Receiver<Msg>, tx_wake: Sender<Msg>) {
    let mut engine: Option<Engine> = None;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Wake => {
                if let Some(e) = engine.as_ref() {
                    e.spin();
                }
            }
            Msg::Shutdown => break,
            Msg::Call(op, reply) => {
                let _ = reply.send(dispatch(&mut engine, op, &tx_wake));
            }
        }
    }
    // Engine drops here: servo shuts down on the engine thread.
}

fn dispatch(engine: &mut Option<Engine>, op: ReqOp, tx_wake: &Sender<Msg>) -> Result<Reply, String> {
    match op {
        ReqOp::Boot {
            width,
            height,
            resources,
            user_agent,
        } => {
            if engine.is_some() {
                return Ok(Reply::Unit); // idempotent boot
            }
            *engine = Some(Engine::new(width, height, resources, user_agent, tx_wake)?);
            Ok(Reply::Unit)
        }
        ReqOp::AliveP => Ok(Reply::Bool(engine.is_some())),
        other => {
            let e = engine
                .as_ref()
                .ok_or_else(|| "eservo: embedded engine not booted".to_string())?;
            e.call(other)
        }
    }
}

impl Engine {
    fn new(
        width: u32,
        height: u32,
        _resources: String,
        _user_agent: String,
        tx_wake: &Sender<Msg>,
    ) -> Result<Engine, String> {
        // PIN(servo-0.8): crypto provider.  The official winit example
        // installs rustls' aws-lc-rs provider before building servo.  With
        // a crates.io servo dependency the provider belongs to servo's own
        // rustls instance; if HTTPS fetches fail at runtime during the
        // pin job, add a matching `rustls` dependency here and install
        // the provider before ServoBuilder::build().

        // PIN(servo-0.8): constructor signature.  The type export is
        // verified (servo::SoftwareRenderingContext / OffscreenRendering-
        // Context); the offscreen construction path is exercised by
        // konippi/servo-fetch (crates/servo-fetch/src/screenshot.rs) --
        // mirror its exact call if this signature differs.
        let ctx = Rc::new(
            SoftwareRenderingContext::new(Size2D::new(width, height))
                .map_err(|e| format!("eservo: software rendering context: {e:?}"))?,
        );
        // Verified in the winit example: make_current before use.
        let _ = ctx.make_current();

        // Verified in the winit example: builder shape.  PIN note: the
        // user-agent knob lives on ServoBuilder in servoshell; wire
        // _user_agent here once the pin compile confirms the method name.
        let waker = ChannelWaker {
            tx: tx_wake.clone(),
        };
        let servo_engine = ServoBuilder::default()
            .event_loop_waker(Box::new(waker))
            .build();

        let state = Rc::new(PageState::default());
        let delegate = Rc::new(PageDelegate {
            state: state.clone(),
        });
        let url =
            Url::parse("about:blank").map_err(|e| format!("eservo: about:blank: {e}"))?;
        let webview = WebViewBuilder::new(&servo_engine, ctx.clone())
            .url(url)
            .hidpi_scale_factor(Scale::new(1.0f32))
            .delegate(delegate)
            .build();

        Ok(Engine {
            servo: servo_engine,
            ctx,
            webview,
            state,
        })
    }

    fn spin(&self) {
        self.servo.spin_event_loop();
    }

    fn call(&self, op: ReqOp) -> Result<Reply, String> {
        match op {
            ReqOp::Goto(url) => {
                let parsed =
                    Url::parse(&url).map_err(|e| format!("eservo: bad URL {url}: {e}"))?;
                let before = self.state.frame_count();
                self.webview.load(parsed);
                // Documented embedding contract: calls to WebView methods
                // must be followed by spin_event_loop.
                self.spin();
                // PIN(servo-0.8): until load-complete notifications are
                // wired in PageDelegate, a new rendered frame is the
                // heuristic that the navigation produced something.
                let deadline = Instant::now() + LOAD_TIMEOUT;
                while self.state.frame_count() <= before {
                    if Instant::now() >= deadline {
                        return Err(format!(
                            "eservo: goto {url}: no new frame within {} s",
                            LOAD_TIMEOUT.as_secs()
                        ));
                    }
                    std::thread::sleep(Duration::from_millis(10));
                    self.spin();
                }
                self.state.record_load(&url);
                // PIN(servo-0.8): post-redirect URL (see PageStateInner).
                Ok(Reply::Str(url))
            }
            ReqOp::Url => Ok(Reply::Str(self.state.current_url())),
            ReqOp::Resize { width, height } => {
                // Verified in the winit example (WindowEvent::Resized).
                self.webview.resize(Size2D::new(width, height));
                self.spin();
                Ok(Reply::Unit)
            }
            ReqOp::Screenshot(path) => {
                // Verified surface: WebView::paint + present (the winit
                // example's redraw path).  PIN(servo-0.8): the pixel
                // readback -- reading the software framebuffer into
                // bytes, then encoding PNG -- is exactly what
                // konippi/servo-fetch does in crates/servo-fetch/src/
                // screenshot.rs; copy that call here during the pin job.
                // Until then this op fails honestly instead of guessing.
                let _ = self.webview.paint();
                self.ctx.present();
                Err(format!(
                    "eservo: screenshot pixel readback is PIN-pending against \
                     servo 0.8 (docs/EMBEDDED-SERVO.org, pin list); \
                     nothing was written to {path}"
                ))
            }
            ReqOp::Keys(_keys) => Err(
                "eservo: keys needs the servo::InputEvent::Keyboard constructor \
                 -- PIN item (docs/EMBEDDED-SERVO.org, pin list)"
                    .to_string(),
            ),
            ReqOp::Snapshot
            | ReqOp::Fill { .. }
            | ReqOp::Click(_)
            | ReqOp::Extract(_)
            | ReqOp::Evaluate(_)
            | ReqOp::WaitSelector { .. } => Err(
                "eservo: DOM ops need the JS-evaluation seam -- PIN item \
                 (docs/EMBEDDED-SERVO.org, pin list)"
                    .to_string(),
            ),
            // Handled by dispatch(); unreachable here.
            ReqOp::Boot { .. } | ReqOp::AliveP => Ok(Reply::Unit),
        }
    }
}
