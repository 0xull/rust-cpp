#!/usr/bin/env bash
# Checks whether header and Config::file edits rebuild the C++ code of a crate that uses cpp.
#
# Usage: bash check-headers.sh <path to rust-cpp clone> <stock|patched> [compiler]
#   stock:   uses cpp and cpp_build 0.5.12 from crates.io
#   patched: uses the crates in your rust-cpp clone
#   compiler: optional value for CXX, for example clang++ or g++
set -u
# pwd -W gives a Windows path in Git Bash, which cargo needs inside Cargo.toml.
RUST_CPP=$(cd "$1" && { pwd -W 2>/dev/null || pwd; })
MODE=$2
COMPILER=${3:-}
BASE=${TMPDIR:-/tmp}/cpp-headers-$MODE${COMPILER:+-$COMPILER}
rm -rf "$BASE"
mkdir -p "$BASE/crate/src" "$BASE/vendor/include/vendor" "$BASE/vendör/include/accent"
if [ -n "$COMPILER" ]; then export CXX=$COMPILER; fi
CRATE=$BASE/crate

PATCH=""
if [ "$MODE" = patched ]; then
    PATCH="
[patch.crates-io]
cpp = { path = \"$RUST_CPP/cpp\" }
cpp_build = { path = \"$RUST_CPP/cpp_build\" }
cpp_common = { path = \"$RUST_CPP/cpp_common\" }
cpp_macros = { path = \"$RUST_CPP/cpp_macros\" }"
fi
cat > "$CRATE/Cargo.toml" <<EOF
[package]
name = "check-headers"
version = "0.0.0"
edition = "2021"

[dependencies]
cpp = "=0.5.12"

[build-dependencies]
cpp_build = "=0.5.12"
$PATCH
EOF
cat > "$CRATE/build.rs" <<'EOF'
fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    let generated = format!("{out}/generated.cpp");
    std::fs::write(&generated, "int generated() { return 1000; }\n").unwrap();
    cpp_build::Config::new()
        .include("../vendor/include")
        .include("../vendör/include")
        .file("src/helper.cpp")
        .file(&generated)
        .build("src/lib.rs");
}
EOF
cat > "$CRATE/src/lib.rs" <<'EOF'
use cpp::cpp;
cpp! {{
    #include "src/header.h"
    #include <vendor/util.h>
    #include <accent/accent.h>
    int helper();
    int generated();
}}
pub fn values() -> [i32; 5] {
    unsafe {
        [
            cpp!([] -> i32 as "int" { return header_value(); }),
            cpp!([] -> i32 as "int" { return util(); }),
            cpp!([] -> i32 as "int" { return helper(); }),
            cpp!([] -> i32 as "int" { return generated(); }),
            cpp!([] -> i32 as "int" { return accent(); }),
        ]
    }
}
#[test]
fn print() { println!("VALUES {:?}", values()); }
EOF
printf '#pragma once\n#include "nested.h"\n#ifdef NEVER_DEFINED\n#include "unused.h"\n#endif\ninline int header_value() { return nested_value(); }\n' > "$CRATE/src/header.h"
printf 'inline int nested_value() { return 1; }\n' > "$CRATE/src/nested.h"
printf 'this file is never included\n' > "$CRATE/src/unused.h"
printf '#pragma once\ninline int util() { return 10; }\n' > "$BASE/vendor/include/vendor/util.h"
printf '#pragma once\ninline int accent() { return 7; }\n' > "$BASE/vendör/include/accent/accent.h"
printf '#include "header.h"\nint helper() { return 100; }\n' > "$CRATE/src/helper.cpp"

values() { (cd "$CRATE" && cargo test -q -- --nocapture 2>&1 | grep -oE 'VALUES \[[0-9, ]+\]|^error.*' | head -n 1); }
reran() { (cd "$CRATE" && cargo build -v 2>&1 | grep -qE 'Running .*build[-_]script[-_]build' && echo rerun || echo fresh); }

echo "== $MODE ${COMPILER:-default compiler}, $(uname -s)"
(cd "$CRATE" && cargo build -q 2>&1 | tail -n 3)
echo "start                      $(values)"
echo "no-op rebuilds             $(reran) $(reran)"
sleep 1; printf 'inline int nested_value() { return 2; }\n' > "$CRATE/src/nested.h"
echo "edit nested header         $(values)"
sleep 1; printf '#pragma once\ninline int util() { return 20; }\n' > "$BASE/vendor/include/vendor/util.h"
echo "edit header outside crate  $(values)"
sleep 1; printf '#include "header.h"\nint helper() { return 200; }\n' > "$CRATE/src/helper.cpp"
echo "edit Config::file source   $(values)"
sleep 1; printf '#pragma once\ninline int accent() { return 8; }\n' > "$BASE/vendör/include/accent/accent.h"
echo "edit non-ASCII dir header  $(values)"
sleep 1; printf 'still never included\n' > "$CRATE/src/unused.h"
echo "edit #ifdef-ed header      $(reran)"
echo "no-op rebuild              $(reran)"
sleep 1; printf '\n' >> "$CRATE/src/lib.rs"
echo "edit src/lib.rs (control)  $(reran)"
# Touching build.rs reruns the build script, and -vv shows what it printed.
sleep 1; printf '\n' >> "$CRATE/build.rs"
LINES=$(cd "$CRATE" && cargo build -vv 2>&1 | grep -o 'cargo:rerun-if-changed=.*' | tr -d '\r')
echo "rerun-if-changed lines:"
echo "$LINES" | sed 's|^|    |'
echo "duplicate lines            $(echo "$LINES" | sort | uniq -d | grep -c . )"
