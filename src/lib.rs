//! Fluxa 行為模擬器（Kahn 程序網路直譯器）。
//!
//! 類比 `iverilog` + `vvp`：`load` 負責解析與編譯期常數求值，
//! `run_test` 為每個 `test` 區塊建立獨立的模擬世界並執行。

pub mod ast;
pub mod interp;
pub mod lexer;
pub mod parser;
pub mod runtime;
pub mod value;

use ast::{Program, TestDecl};
use interp::Interp;
use runtime::{RtErr, Shared};
use std::sync::Arc;
use std::time::Instant;
use value::coerce;

pub struct Options {
    pub trace: bool,
    pub stats: bool,
}

pub struct TestResult {
    pub name: String,
    pub passed: bool,
    pub message: String,
    pub secs: f64,
    pub stats: String,
}

/// 解析原始碼並求值編譯期常數
pub fn load(file: &str, src: &str) -> Result<Arc<Program>, String> {
    let prog = parser::parse_program(file, src).map_err(|e| format!("{}:{}: syntax error: {}", file, e.line, e.msg))?;
    let prog = Arc::new(prog);
    let sh = Shared::new(prog.clone(), false);
    let mut it = Interp::new(sh, 0, "const".to_string());
    for c in &prog.consts_decl {
        let fail = |line: u32, m: String| format!("{}:{}: in const `{}`: {}", file, line, c.name, m);
        it.line = c.line;
        let mut v = it.eval(&c.value).map_err(|e| match e {
            RtErr::Msg(l, m) => fail(l, m),
            other => fail(c.line, format!("{:?}", other)),
        })?;
        if let Some(t) = &c.ty {
            let rt = it.eval_type(t).map_err(|e| match e {
                RtErr::Msg(l, m) => fail(l, m),
                other => fail(c.line, format!("{:?}", other)),
            })?;
            v = coerce(v, &rt).map_err(|m| fail(c.line, m))?;
        }
        prog.consts.write().unwrap().insert(c.name.clone(), v);
    }
    Ok(prog)
}

pub fn run_test(prog: &Arc<Program>, t: &TestDecl, opts: &Options) -> TestResult {
    let sh = Shared::new(prog.clone(), opts.trace);
    let mut it = Interp::new(sh.clone(), 0, format!("test:{}", t.name));
    let start = Instant::now();
    let r = it.exec_block(&t.body);
    sh.finish_test();
    sh.join_all();
    let secs = start.elapsed().as_secs_f64();
    let (child_err, deadlock) = {
        let w = sh.lock();
        (w.error.clone(), w.deadlock_report.clone())
    };
    let failure: Option<String> = match r {
        Ok(_) | Err(RtErr::Ret(_)) => child_err,
        Err(RtErr::Msg(l, m)) => Some(format!("{}:{}: {}", prog.file, l, m)),
        Err(RtErr::Deadlock) => deadlock,
        Err(RtErr::Shutdown) => child_err.or(deadlock),
    };
    TestResult {
        name: t.name.clone(),
        passed: failure.is_none(),
        message: failure.unwrap_or_default(),
        secs,
        stats: if opts.stats { sh.stats_report() } else { String::new() },
    }
}
