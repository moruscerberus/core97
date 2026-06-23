# Scripted apps: a tiny VM + SDK on top of window.App

Design sketch only - nothing in this doc is implemented yet. Written
now because the windowing refactor (gui/window.zig's WindowManager +
AppVTable) was built specifically so this could plug in cleanly later
without another architecture change.

## The key idea

A "native" app (Notepad, Explorer) implements `window.AppVTable` by
pointing its function pointers at real Zig functions compiled into the
kernel. A *scripted* app implements the exact same `AppVTable` - but
each function pointer is a small trampoline that resumes a bytecode
interpreter instead of running real Zig code:

```
window.App (interface)
   |
   +-- NotepadApp      (vtable fns -> notepad.zig functions directly)
   +-- ExplorerApp     (vtable fns -> file_explorer.zig functions directly)
   +-- ScriptedApp     (vtable fns -> vm.resume(event) -> host calls)
```

This means `WindowManager` never needs to know scripted apps exist at
all. No process model, no paging, no ELF loader, no usermode - the
interpreter itself is the sandbox (it can't form a raw pointer or jump
outside its own bytecode array), which is exactly what's achievable
given the kernel has no allocator yet (Phase 3) and no usermode (not on
the roadmap at all right now).

## Non-goals (for now)

- Not a general-purpose language. No functions-as-values, no closures,
  no dynamic typing beyond a handful of fixed types.
- Not compiled ahead-of-time. Scripts are parsed/compiled to bytecode
  by the kernel itself, at app-launch time, from a plain text file.
- Not memory-safe in the sense of bounds-checked arbitrary host memory
  access, because there *is* no host memory access - scripts only ever
  touch their own VM-private memory and the host-call table below.

## Where scripts live

Plain text files in the existing RAM VFS, e.g. `/apps/calc.ws`. A
`.ws` (Win Script) file is just source text - the interpreter compiles
it to bytecode when the app is launched, holds the bytecode + VM state
for the lifetime of that window, and discards it on close. No new VFS
node type needed.

## Bytecode VM sketch

Stack machine, byte-sized opcodes, a fixed-size value stack and a
fixed-size set of named variables (no heap, matches the rest of this
kernel's static-pool style). A `Value` is a tagged union of `i32`,
`bool`, and a fixed-length string slice into the script's own constant
pool (no dynamic string allocation).

Minimal opcode set to start:

| Opcode        | Stack effect           | Meaning                         |
|---------------|-------------------------|----------------------------------|
| `PUSH_INT n`  | `-> n`                  | push a constant                  |
| `PUSH_STR i`  | `-> str`                | push constant-pool string `i`    |
| `LOAD var`    | `-> v`                  | push variable's value            |
| `STORE var`   | `v ->`                  | pop into variable                |
| `ADD/SUB/MUL/DIV` | `a b -> a±b`        | arithmetic                       |
| `EQ/LT/GT`    | `a b -> bool`           | comparison                       |
| `JMP addr`    | `->`                    | unconditional jump                |
| `JMPF addr`   | `cond ->`               | jump if false                     |
| `CALL host_id`| `args... -> result`     | invoke a host call (below)        |
| `RET`         | `->`                    | return from the current event handler |

A script is compiled into one bytecode blob per **event handler**
(`on_draw`, `on_click`, `on_key`), since that maps directly onto
`AppVTable`'s separate functions - no general control-flow-across-events
needed, which keeps the compiler simple (closer to a calculator-grammar
recursive-descent parser than a real language frontend).

## Host calls (the "syscalls")

These are the only way a script touches anything outside its own VM
state - this list *is* the SDK surface:

```
draw_rect(x, y, w, h, color)
draw_text(x, y, str, fg, bg)
draw_3d_border(x, y, w, h, raised)
get_mouse_x() / get_mouse_y() / mouse_button_down()
get_content_w() / get_content_h()      -- current content-area size
fs_read(path) -> str
fs_write(path, str) -> bool
set_var(name, value) / get_var(name)   -- persisted across redraws
request_redraw()
```

Each is just a Zig function with a fixed signature, dispatched by
`host_id` through a `switch` - the same shape as `idt.outb`/`inb`, just
one level up. Adding a host call later means adding one `switch` arm,
not touching the VM core.

## Wiring into AppVTable

```zig
const ScriptedApp = struct {
    vm: Vm,

    fn vtDraw(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void {
        const self: *ScriptedApp = @ptrCast(@alignCast(ptr));
        self.vm.run(self.vm.on_draw_addr, .{ .content = .{ x, y, w, h } });
    }
    // onMouseDown/onKeyAscii/etc. follow the same shape: forward the
    // event into the VM at the matching entry point, let host calls
    // during that run do the actual drawing/state changes.
};
```

`ScriptedApp` needs a `*anyopaque`-stable home for its `Vm` (one of
`WindowManager`'s currently-unused slots 2..7), and a small manifest -
just a name + which `.ws` file to load - so the Start menu can list it
without the kernel needing to know about it ahead of time. That manifest
format and a "Programs" listing pulled from `/apps/*.manifest` (instead
of the hardcoded Programs flyout) is the natural next piece once the VM
itself exists.

## Suggested build order

1. **Expression VM only** - PUSH/arithmetic/STORE/LOAD/CALL, no control
   flow yet. Enough to test the host-call mechanism end to end with a
   single `on_draw` handler (e.g. a script that just draws a colored
   rectangle).
2. **Control flow** - JMP/JMPF, enough for a real `on_click` handler
   that branches on which button was pressed.
3. **One real toy app** - a calculator: a few `draw_rect`/`draw_text`
   calls for the keypad, `on_click` to accumulate digits/operators,
   `set_var`/`get_var` for the running total. This is the actual proof
   the SDK works, not the VM in isolation.
4. **Manifest-driven Programs menu** - list `/apps/*.manifest` instead
   of the hardcoded Notepad/Explorer flyout, so a new app means dropping
   a `.ws` + manifest file into the VFS, not touching kernel source.

Steps 1-3 don't need anything from Phase 3/4 of the roadmap (no
allocator, no storage) - the VM's own memory is static pools, same as
everywhere else in this kernel. Step 4 benefits from Phase 4 storage
(so a dropped-in app file survives reboot) but doesn't strictly need it
either.
