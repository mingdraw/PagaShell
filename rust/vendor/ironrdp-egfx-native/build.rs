fn main() {
    println!("cargo:rustc-check-cfg=cfg(paga_vaapi)");
    match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") => {
            println!("cargo:rerun-if-changed=src/video_toolbox.c");
            println!("cargo:rerun-if-changed=src/metal_compositor.m");
            cc::Build::new()
                .file("src/video_toolbox.c")
                .compile("paga_rdp_videotoolbox");
            cc::Build::new()
                .file("src/metal_compositor.m")
                .flag("-fobjc-arc")
                .compile("paga_rdp_metal_compositor");
            for framework in [
                "CoreFoundation",
                "CoreMedia",
                "CoreVideo",
                "Foundation",
                "Metal",
                "VideoToolbox",
            ] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
        Ok("linux") => {
            println!("cargo:rerun-if-changed=src/vaapi.c");
            let headers = |name| pkg_config::Config::new().cargo_metadata(false).probe(name);
            if let (Ok(codec), Ok(util)) = (headers("libavcodec"), headers("libavutil")) {
                // Use the distribution's ABI headers only. The libraries are
                // loaded on demand and are not required to launch the app.
                cc::Build::new()
                    .file("src/vaapi.c")
                    .includes(codec.include_paths)
                    .includes(util.include_paths)
                    .compile("paga_rdp_vaapi");
                println!("cargo:rustc-link-lib=dl");
                println!("cargo:rustc-cfg=paga_vaapi");
            }
        }
        _ => {}
    }
}
