// With `--features header`, regenerates ../include/yrby_ffi.h from the
// `extern "C"` items, as Marco's gems do on every build. The header is
// checked in, so a plain build doesn't need cbindgen.
fn main() {
    #[cfg(feature = "header")]
    {
        let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        let header = std::path::Path::new(&crate_dir).join("../include/yrby_ffi.h");
        cbindgen::generate(&crate_dir)
            .expect("cbindgen failed")
            .write_to_file(header);
    }
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=cbindgen.toml");
}
