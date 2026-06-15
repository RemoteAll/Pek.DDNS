fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").unwrap() == "windows" {
        let mut res = winres::WindowsResource::new();
        res.set_manifest_file("Hlk.RFixHosts.exe.manifest");
        res.compile().expect("编译 Windows 资源失败");
    }
}
