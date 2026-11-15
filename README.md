# Ilgi (일기)

Local-first Markdown & knowledge vault built in Zig on top of the offline [ivanleomk/nanoui](https://github.com/ivanleomk/nanoui) fork.

## Getting Started

Requires **Zig 0.17.0**.

On first build, fetch the pinned `nanoui` dependency hash into `build.zig.zon`:

```sh
zig fetch --save=nanoui git+https://github.com/ivanleomk/nanoui#310b7fa92f49126bee69baa2a70ee7835103ba23
zig build test
zig build run
```
