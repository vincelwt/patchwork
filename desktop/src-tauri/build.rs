fn main() {
    #[cfg(target_os = "macos")]
    build_dictation();
    tauri_build::build()
}

/// Dictation is Apple's `SpeechTranscriber`, which is a Swift-only API, so a
/// small Swift file is compiled into a static library and linked here. The
/// Swift runtime has been ABI stable and shipped with macOS since 5.5, so
/// linking against `/usr/lib/swift` asks nothing of the user's machine.
#[cfg(target_os = "macos")]
fn build_dictation() {
    use std::path::PathBuf;
    use std::process::Command;

    let source = "swift/Dictation.swift";
    println!("cargo:rerun-if-changed={source}");

    let out = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let lib = out.join("libpwdictation.a");
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-emit-library",
            "-static",
            "-O",
            "-parse-as-library",
            "-module-name",
            "pwdictation",
            source,
            "-o",
        ])
        .arg(&lib)
        .status()
        .expect("swiftc: install the Xcode command line tools");
    assert!(status.success(), "failed to build {source}");

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=pwdictation");
    println!("cargo:rustc-link-search=native=/usr/lib/swift");
    for lib in ["swiftCore", "swift_Concurrency", "swiftFoundation"] {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    for framework in ["Speech", "AVFoundation", "AVFAudio", "Foundation"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
