use std::os::fd::AsFd;
use std::error::Error;
use std::time::{Duration, Instant};

use calloop::generic::Generic;
use calloop::{Interest, Mode, PostAction};
use calloop::ping::make_ping;
use calloop::timer::{TimeoutAction, Timer};
use calloop::EventLoop;
use polling::{Event, Events, Poller};
use rustix::io::{read, write};
use rustix::pipe::pipe;

struct State {
    started: Instant,
    timer: Option<Duration>,
    ping: bool,
    pipe: bool,
    payload: bool,
}

fn process_cpu_seconds() -> Result<f64, Box<dyn Error>> {
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        usage
    };
    let cpu = |time: libc::timeval| time.tv_sec as f64 + time.tv_usec as f64 / 1_000_000.0;
    Ok(cpu(usage.ru_utime) + cpu(usage.ru_stime))
}

fn idle_check() -> Result<(), Box<dyn Error>> {
    let mut event_loop = EventLoop::<()>::try_new()?;
    let (reader, writer) = pipe()?;
    let mut events = Vec::new();
    for _ in 0..50 {
        let (reader, writer) = pipe()?;
        event_loop.handle().insert_source(
            Generic::new(reader, Interest::READ, Mode::Level),
            |_, _, _| Ok(PostAction::Continue))?;
        events.push(writer);
    }
    let before = process_cpu_seconds()?;
    event_loop.dispatch(Duration::from_secs(5), &mut ())?;
    let elapsed = process_cpu_seconds()? - before;
    println!("{} 7 - 50 idle fds use less than 0.2 s CPU over 5 s ({elapsed:.6} s)",
        if elapsed < 0.2 { "ok" } else { "not ok" });
    drop(events);
    drop(reader);
    drop(writer);
    if elapsed >= 0.2 { return Err("idle event loop used too much CPU".into()); }
    Ok(())
}

fn run() -> Result<(), Box<dyn Error>> {
    let mut event_loop = EventLoop::<State>::try_new()?;
    let handle = event_loop.handle();
    handle.insert_source(Timer::from_duration(Duration::from_millis(100)),
        |_, _, state| {
            state.timer = Some(state.started.elapsed());
            TimeoutAction::Drop
        })?;
    let (ping, ping_source) = make_ping()?;
    handle.insert_source(ping_source, |_, _, state| state.ping = true)?;
    let (reader, writer) = pipe()?;
    handle.insert_source(Generic::new(reader, Interest::READ, Mode::Level),
        |_, reader, state| {
            let mut payload = [0u8; 7];
            state.pipe = read(&reader.as_fd(), &mut payload)? == 7;
            state.payload = payload == *b"calloop";
            Ok(PostAction::Continue)
        })?;
    println!("ok 1 - calloop timer, ping, and pipe sources registered");
    ping.ping();
    write(&writer, b"calloop")?;
    let mut state = State { started: Instant::now(), timer: None, ping: false, pipe: false, payload: false };
    for _ in 0..3 {
        event_loop.dispatch(Duration::from_millis(500), &mut state)?;
        if state.timer.is_some() { break; }
    }
    let elapsed = state.timer.map(|d| d.as_millis()).unwrap_or(0);
    println!("{} 2 - timer fired within 80..120 ms ({} ms)",
        if (80..=120).contains(&elapsed) { "ok" } else { "not ok" }, elapsed);
    println!("{} 3 - ping woke the loop", if state.ping { "ok" } else { "not ok" });
    println!("{} 4 - pipe readiness and payload reached calloop",
        if state.pipe && state.payload { "ok" } else { "not ok" });
    if elapsed < 80 || elapsed > 120 || !state.ping || !state.pipe || !state.payload {
        return Err("calloop assertions failed".into());
    }

    let poller = Poller::new()?;
    let (reader, writer) = pipe()?;
    let mut read_check = reader.try_clone()?;
    unsafe { poller.add(&reader, Event::new(7, true, false))?; }
    write(&writer, b"polling")?;
    let mut events = Events::new();
    poller.wait(&mut events, Some(Duration::from_secs(1)))?;
    let ready = events.iter().any(|event| event.key == 7 && event.readable);
    println!("{} 5 - polling directly reports pipe readability", if ready { "ok" } else { "not ok" });
    let mut payload = [0u8; 7];
    read(&mut read_check, &mut payload)?;
    let delivered = payload == *b"polling";
    println!("{} 6 - polling pipe payload delivered", if delivered { "ok" } else { "not ok" });
    poller.delete(&reader)?;
    if !ready || !delivered { return Err("polling assertions failed".into()); }
    idle_check()?;
    let value = std::thread::spawn(|| 42).join().map_err(|_| "Rust thread panicked")?;
    println!("{} 8 - Rust std thread completes", if value == 42 { "ok" } else { "not ok" });
    if value != 42 { return Err("Rust thread returned the wrong value".into()); }
    Ok(())
}

fn main() {
    println!("TAP version 13");
    match run() {
        Ok(()) => println!("1..8"),
        Err(error) => {
            println!("not ok - event-loop test failed: {error}");
            println!("1..8");
            std::process::exit(1);
        }
    }
}
