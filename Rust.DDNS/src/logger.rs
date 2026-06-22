use chrono::Local;
use std::io::Write;

/// 日志级别
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

impl Level {
    fn color(&self) -> &str {
        match self {
            Level::Debug => "\x1b[36m", // 青色
            Level::Info => "\x1b[32m",  // 绿色
            Level::Warn => "\x1b[33m",  // 黄色
            Level::Error => "\x1b[31m", // 红色
        }
    }

    fn label(&self) -> &str {
        match self {
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
        }
    }
}

/// 全局日志级别
static mut GLOBAL_LEVEL: Level = Level::Debug;

/// 设置全局日志级别
#[allow(dead_code)]
pub fn set_level(level: Level) {
    unsafe {
        GLOBAL_LEVEL = level;
    }
}

/// 获取当前日志级别
#[allow(dead_code)]
pub fn current_level() -> Level {
    unsafe { GLOBAL_LEVEL }
}

/// Windows 下使用 WriteConsoleW 确保中文正确显示
#[cfg(windows)]
fn print_to_console(text: &str) {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;

    let handle = unsafe {
        kernel32::GetStdHandle(kernel32::STD_OUTPUT_HANDLE)
    };
    if handle.is_null() || handle == kernel32::INVALID_HANDLE_VALUE {
        let _ = std::io::stdout().write_all(text.as_bytes());
        return;
    }

    let wide: Vec<u16> = OsStr::new(text)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();

    unsafe {
        kernel32::WriteConsoleW(
            handle,
            wide.as_ptr() as *const _,
            wide.len() as u32 - 1,
            &mut 0,
            ptr::null_mut(),
        );
    }
}

#[cfg(not(windows))]
fn print_to_console(text: &str) {
    let _ = std::io::stdout().write_all(text.as_bytes());
}

/// 通用日志打印函数
pub fn log(level: Level, fmt: std::fmt::Arguments<'_>) {
    unsafe {
        if (level as u8) < (GLOBAL_LEVEL as u8) {
            return;
        }
    }

    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let message = std::fmt::format(fmt);

    let color = level.color();
    let reset = "\x1b[0m";
    let label = level.label();

    let full = format!("{color}[{timestamp}] {color}{label}{reset} {message}\n");
    print_to_console(&full);
}

/// 调试级别日志
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::Level::Debug, format_args!($($arg)*));
    };
}

/// 信息级别日志
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::Level::Info, format_args!($($arg)*));
    };
}

/// 警告级别日志
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::Level::Warn, format_args!($($arg)*));
    };
}

/// 错误级别日志
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::Level::Error, format_args!($($arg)*));
    };
}

// Windows kernel32 绑定
#[cfg(windows)]
mod kernel32 {
    use std::ffi::c_void;
    #[allow(unused_imports)]
    use std::os::raw::c_uint;

    pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5u32;
    pub const INVALID_HANDLE_VALUE: *mut c_void = !0 as *mut c_void;

    pub type DWORD = u32;
    pub type LPCVOID = *const c_void;
    pub type LPDWORD = *mut DWORD;
    pub type LPVOID = *mut c_void;
    pub type HANDLE = LPVOID;

    extern "system" {
        pub fn GetStdHandle(nStdHandle: DWORD) -> HANDLE;
        pub fn WriteConsoleW(
            hConsoleOutput: HANDLE,
            lpBuffer: LPCVOID,
            nNumberOfCharsToWrite: DWORD,
            lpNumberOfCharsWritten: LPDWORD,
            lpReserved: LPVOID,
        ) -> i32;
    }
}
