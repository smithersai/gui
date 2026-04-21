# Clipboard Read Ownership

## Need

The macOS host cannot safely implement `smithers_runtime_config_s.read_clipboard`
as currently declared:

```c
bool (*read_clipboard)(smithers_userdata_t, smithers_string_s *out);
```

`smithers_string_s` is documented elsewhere as core-owned and freed with
`smithers_string_free`, but clipboard contents originate in Swift/AppKit. The
ABI does not provide a host-owned free callback, a core allocator entrypoint, or
a guarantee that core copies the bytes before the callback returns. Returning
Swift string storage would therefore be an unsafe pointer escape; returning
malloc-owned storage would leave ownership undefined.

## Proposed Header Diff

One safe option is to make the callback explicitly copy-only:

```diff
-  bool (*read_clipboard)(smithers_userdata_t, smithers_string_s *out);
+  // Host returns clipboard bytes borrowed only for the duration of this call.
+  // Core must copy synchronously before returning from the callback and must
+  // never pass the result to smithers_string_free.
+  bool (*read_clipboard)(smithers_userdata_t, smithers_string_s *out);
```

If core needs to retain the data after the callback, prefer an explicit
completion API instead:

```diff
+typedef void *smithers_clipboard_request_t;
+void (*read_clipboard)(smithers_userdata_t, smithers_clipboard_request_t request);
+SMITHERS_API void smithers_clipboard_read_complete(
+    smithers_clipboard_request_t request,
+    const char *text,
+    size_t len);
```

The completion shape mirrors Ghostty's clipboard request pattern and keeps all
retained storage inside libsmithers.

## Affected Streams

- Stream A: define and implement the ownership semantics in `libsmithers`.
- Stream B: update GTK clipboard read implementation to the accepted shape.
- Stream C: update Swift `Smithers.App.readClipboard` to return real clipboard
  contents once ownership is explicit.
