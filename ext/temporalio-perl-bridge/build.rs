// ABOUTME: Build script for temporalio-perl-bridge: runs cbindgen to keep
// ABOUTME: include/temporalio-perl-bridge.h in sync with the src/lib.rs C ABI.

fn main() {
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");

    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let config = cbindgen::Config::from_file(format!("{crate_dir}/cbindgen.toml"))
        .expect("failed to load cbindgen.toml");
    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("cbindgen header generation failed")
        .write_to_file(format!("{crate_dir}/include/temporalio-perl-bridge.h"));
}
