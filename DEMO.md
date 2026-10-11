# ndap.nvim demos

Each clip is a recorded Neovim session debugging the same small Python program
through [debugpy](https://github.com/microsoft/debugpy). Commands are typed in
full (`:Ndap …`) to show what each step does; map them to keys for daily use,
see [Keymaps example](README.md#keymaps-example).

<details>
<summary><b>Breakpoints, stepping and the debug view</b></summary>

Set a breakpoint and launch. The debug view opens on the stop, showing sessions, call
stack, locals, watch expressions and breakpoints in one tree; the frame's values
are rendered inline in the source.

![Breakpoints and stepping](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/01-breakpoint-step.gif)

</details>

<details>
<summary><b>Conditions and logpoints</b></summary>

A breakpoint that only stops when `amount > 50`, and a logpoint that prints
every scaling operation without pausing the program.

![Conditional breakpoints and logpoints](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/02-condition-logpoint.gif)

</details>

<details>
<summary><b>Function and exception breakpoints</b></summary>

Break on `scale` by name wherever it is called from, then run into the
program's uncaught `ValueError` and read it with `:Ndap exception_info`.

![Function and exception breakpoints](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/03-function-exception.gif)

</details>

<details>
<summary><b>Inspecting and changing values</b></summary>

`:Ndap inspect` expands the identifier under the cursor, `i` in the debug view adds
a watch expression, and `c` on a variable writes a new value back into the
running program.

![Inspect and watch expressions](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/04-watch-inspect.gif)

</details>

<details>
<summary><b>REPL and run buffers</b></summary>

Each run has its own buffers: progress log, REPL, adapter terminal and program
output. The REPL evaluates expressions in the stopped frame, function calls
included.

![REPL and run buffers](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/05-repl.gif)

</details>

<details>
<summary><b>Jump to cursor, step in and out</b></summary>

Move the execution point to the cursor without running the code in between,
then step into a call and back out. The return value appears in the locals.

![Jump to cursor and stepping in](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/06-step-in-jump.gif)

</details>

<details>
<summary><b>Parallel sessions</b></summary>

Two debuggees paused at the same breakpoint at once, each with a row in the debug view.
`:Ndap session` selects which one the stepping commands apply to.

![Parallel sessions](https://raw.githubusercontent.com/mbfoss/ndap.nvim/assets/demos/07-parallel-sessions.gif)

</details>
