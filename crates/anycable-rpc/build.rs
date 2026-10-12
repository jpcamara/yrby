// Generates the gRPC service and messages from AnyCable's rpc.proto, vendored
// from anycable/anycable etc/rpc.proto. protoc comes from protoc-bin-vendored,
// so building this crate does not need protoc installed.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    // SAFETY: build scripts are single-threaded.
    unsafe { std::env::set_var("PROTOC", protoc_bin_vendored::protoc_bin_path()?) };
    tonic_prost_build::configure()
        .build_client(true)
        .build_transport(false)
        .compile_protos(&["proto/rpc.proto"], &["proto"])?;
    println!("cargo:rerun-if-changed=proto/rpc.proto");
    Ok(())
}
