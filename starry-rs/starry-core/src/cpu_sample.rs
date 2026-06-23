//! Process-wide CPU time sampling for the debug overlay.
//!
//! Returns cumulative CPU seconds consumed by this process (user + kernel);
//! the caller takes deltas across frames and divides by wall-clock dt to get
//! a CPU%. EMA smoothing happens in the engine, not here.
//!
//! Per-OS implementations, each cfg-gated:
//!
//!   macOS:   `task_info(mach_task_self, TASK_THREAD_TIMES_INFO, ...)` —
//!            mirrors `StarryEngine.swift::sampleCPU`. Sums `user_time` +
//!            `system_time` (both `time_value` = seconds + microseconds).
//!
//!   Linux:   fields 14 (utime) + 15 (stime) of `/proc/self/stat`, converted
//!            from clock ticks to seconds via `sysconf(_SC_CLK_TCK)`. The
//!            comm field can contain whitespace/parens, so we split on the
//!            LAST `)` rather than tokenising the whole line.
//!
//!   Windows: `GetProcessTimes(GetCurrentProcess(), ...)` — kernel + user
//!            FILETIME values are durations in 100-nanosecond intervals.
//!
//!   others:  `None` (overlay will render `CPU: --.- %`).

/// Cumulative CPU seconds consumed by this process (user + kernel time),
/// or `None` if the platform is unsupported or the sampling call failed.
pub fn sample_process_cpu_seconds() -> Option<f64> {
    sample_impl()
}

#[cfg(target_os = "macos")]
#[allow(deprecated)]
fn sample_impl() -> Option<f64> {
    // `libc::mach_task_self` is deprecated in favor of the `mach2` crate, but
    // pulling in a whole extra dep for one symbol that works fine isn't worth
    // it — Swift accesses the same underlying `mach_task_self_` static
    // (StarryEngine.swift line 1432) and the deprecated wrapper does too.
    use libc::{
        KERN_SUCCESS, TASK_THREAD_TIMES_INFO, integer_t, mach_msg_type_number_t, mach_task_self,
        natural_t, task_flavor_t, task_info, task_thread_times_info,
    };

    let mut info: task_thread_times_info = unsafe { std::mem::zeroed() };
    let mut count: mach_msg_type_number_t = (std::mem::size_of::<task_thread_times_info>()
        / std::mem::size_of::<natural_t>())
        as mach_msg_type_number_t;

    let kerr = unsafe {
        task_info(
            mach_task_self(),
            TASK_THREAD_TIMES_INFO as task_flavor_t,
            &mut info as *mut _ as *mut integer_t,
            &mut count,
        )
    };

    if kerr != KERN_SUCCESS {
        return None;
    }

    let user = info.user_time.seconds as f64 + info.user_time.microseconds as f64 / 1_000_000.0;
    let system =
        info.system_time.seconds as f64 + info.system_time.microseconds as f64 / 1_000_000.0;
    Some(user + system)
}

#[cfg(target_os = "linux")]
fn sample_impl() -> Option<f64> {
    let raw = std::fs::read_to_string("/proc/self/stat").ok()?;
    let after_comm = raw.rsplit_once(')')?.1.trim_start();
    let fields: Vec<&str> = after_comm.split_whitespace().collect();
    let utime_ticks: u64 = fields.get(11)?.parse().ok()?;
    let stime_ticks: u64 = fields.get(12)?.parse().ok()?;
    let ticks_per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if ticks_per_sec <= 0 {
        return None;
    }
    Some((utime_ticks + stime_ticks) as f64 / ticks_per_sec as f64)
}

#[cfg(target_os = "windows")]
fn sample_impl() -> Option<f64> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, GetProcessTimes};

    let mut creation: FILETIME = unsafe { std::mem::zeroed() };
    let mut exit: FILETIME = unsafe { std::mem::zeroed() };
    let mut kernel: FILETIME = unsafe { std::mem::zeroed() };
    let mut user: FILETIME = unsafe { std::mem::zeroed() };

    let ok = unsafe {
        GetProcessTimes(
            GetCurrentProcess(),
            &mut creation,
            &mut exit,
            &mut kernel,
            &mut user,
        )
    };
    if ok == 0 {
        return None;
    }

    fn filetime_to_seconds(ft: &FILETIME) -> f64 {
        let combined = ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
        combined as f64 * 100e-9
    }

    Some(filetime_to_seconds(&kernel) + filetime_to_seconds(&user))
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn sample_impl() -> Option<f64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_sample_is_monotonic_when_available() {
        let Some(a) = sample_process_cpu_seconds() else {
            // Unsupported platform — both calls returned None, contract holds vacuously.
            return;
        };

        // Burn a measurable amount of CPU so the second sample has a chance
        // to be strictly greater (not just equal). The assertion below only
        // requires `b >= a`, but the burn loop catches regressions that
        // would silently report zero CPU usage.
        let start = std::time::Instant::now();
        let mut x: u64 = 0;
        while start.elapsed() < std::time::Duration::from_millis(20) {
            x = x.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1);
        }
        std::hint::black_box(x);

        let b = sample_process_cpu_seconds()
            .expect("CPU sampling worked once; it should still work after burning cycles");
        assert!(b >= a, "CPU sample regressed: {a} -> {b}");
    }
}
