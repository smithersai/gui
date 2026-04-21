# cwd fuzz crash

- Target: `cwd`
- UTC timestamp: `20260421T054917Z`
- Repro input: `input.bin`
- Input bytes: `70 72 65 66 69 78 00 73 75 66 66 69 78 ff 0a`

## Summary

The internal resolver path crashed on an embedded NUL byte. The public C ABI
truncates at the first NUL, so the fuzz harness now avoids calling the internal
resolver with bytes that the public ABI cannot represent.

## Stack Trace

```text
thread 3841600 panic: reached unreachable code
/Users/williamcory/.zvm/0.15.2/lib/std/debug.zig:559:14: 0x1046b8953 in assert (fuzz-cwd)
    if (!ok) unreachable; // assertion failure
             ^
/Users/williamcory/.zvm/0.15.2/lib/std/posix.zig:7351:41: 0x1046c896b in toPosixPath (fuzz-cwd)
    if (std.debug.runtime_safety) assert(mem.indexOfScalar(u8, file_path, 0) == null);
                                        ^
/Users/williamcory/.zvm/0.15.2/lib/std/fs/Dir.zig:1497:45: 0x10470d3eb in openDir (fuzz-cwd)
    const sub_path_c = try posix.toPosixPath(sub_path);
                                            ^
/Users/williamcory/.zvm/0.15.2/lib/std/fs.zig:245:25: 0x1046e601f in openDirAbsolute (fuzz-cwd)
    return cwd().openDir(absolute_path, flags);
                        ^
/Users/williamcory/gui/libsmithers/src/workspace/cwd.zig:37:37: 0x1046c383b in isDirectory (fuzz-cwd)
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
                                    ^
/Users/williamcory/gui/libsmithers/src/workspace/cwd.zig:23:55: 0x1046c334f in resolve (fuzz-cwd)
    if (std.mem.eql(u8, resolved, "/") or !isDirectory(resolved)) {
                                                      ^
/Users/williamcory/gui/libsmithers/fuzz/src/cwd.zig:24:31: 0x1046b0de7 in fuzzOne (fuzz-cwd)
    const direct = cwd.resolve(std.testing.allocator, bounded) catch return;
                              ^
```
