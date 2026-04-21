# ABI Change Request: new_session payload

## Problem

`smithers.h` documents `SMITHERS_ACTION_NEW_SESSION` as carrying a
`smithers_session_kind_e` payload, but `smithers_action_s.u` has no
`new_session` union member. `libsmithers/src/apprt/action.zig` therefore has
to emit the action with `_reserved`, which means the payload cannot round-trip
losslessly across the ABI.

## Requested Change

Add a `new_session` union member to `smithers_action_s`:

```c
struct { smithers_session_kind_e kind; } new_session;
```

Then mirror it in `libsmithers/src/apprt/structs.zig` and
`libsmithers/src/apprt/action.zig`.

## Compatibility

This appends/uses an existing reserved payload slot without changing action tag
values. Hosts that currently ignore the payload can continue to do so.
