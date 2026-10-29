use fluxa::{load, run_test, Options};

fn run(file: &str) -> Vec<(String, bool, String)> {
    let path = format!("{}/examples/{}.fx", env!("CARGO_MANIFEST_DIR"), file);
    let src = std::fs::read_to_string(&path).unwrap();
    let prog = load(&path, &src).unwrap_or_else(|e| panic!("{}", e));
    let opts = Options { trace: false, stats: false };
    prog.tests
        .iter()
        .map(|t| {
            let r = run_test(&prog, t, &opts);
            (r.name, r.passed, r.message)
        })
        .collect()
}

fn all_pass(file: &str) {
    for (name, ok, msg) in run(file) {
        assert!(ok, "{}::{} failed: {}", file, name, msg);
    }
}

fn all_fail_with(file: &str, needle: &str) {
    let rs = run(file);
    assert!(!rs.is_empty());
    for (name, ok, msg) in rs {
        assert!(!ok, "{}::{} should have failed", file, name);
        assert!(msg.contains(needle), "{}::{}: expected `{}` in `{}`", file, name, needle, msg);
    }
}

#[test] fn basics() { all_pass("basics"); }
#[test] fn mac() { all_pass("mac"); }
#[test] fn fir() { all_pass("fir"); }
#[test] fn gemm() { all_pass("gemm"); }
#[test] fn fanout() { all_pass("fanout"); }

#[test] fn overflow_is_reported() { all_fail_with("err_overflow", "does not fit i24"); }
#[test] fn deadlock_is_reported() { all_fail_with("err_deadlock", "deadlock"); }
#[test] fn linearity_is_reported() { all_fail_with("err_linear", "does not own the rx endpoint"); }
#[test] fn narrowing_is_reported() { all_fail_with("err_narrow", "does not fit u8"); }

/// 死結偵測不可有競態誤判：重複執行多次都必須通過
#[test]
fn no_false_deadlocks_under_repetition() {
    for _ in 0..100 {
        all_pass("gemm");
        all_pass("fanout");
    }
}
