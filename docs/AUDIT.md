# Pre-change architecture audit — 2026-10-26

Inspected every tracked RTL, testbench and Python source, README, existing vectors,
Git status/history and tool installation before changing RTL. Baseline Git HEAD:
`958afe9`. Existing untracked vectors and Python cache were present on arrival.
Backup: `backups/pre_uart_20261026.zip` (RTL, TB, verification and README).
No AGENTS.md or existing Vivado project, constraints or build scripts were found.

## Actual architecture

The nine RTL files define a single-clock, active-low asynchronous-reset core.
`inference_accelerator_top` exposes 64-bit AXI input/output, an unacknowledged
10-bit-address/64-bit-data weight write port, a packed 68-bit layer descriptor,
start/abort, status and eight counters. These are internal system interfaces,
not suitable board pins. No physical interface or reset synchronizer exists.

`sram_controller` holds two 1024x64 banks (8 KiB each). Writes target the inactive
bank, reads the active bank; LOAD_WEIGHTS completion swaps banks. Read latency is
two cycles. All weights for a layer must fit ONE bank: K*N <= 8192 bytes, despite
the independent MAX_CHANNELS=512 setting. There is no external DDR controller.

Input byte r carries activation k+r; diagonal delays inject these into array row
r. Weights stream eight consecutive rows per tile, each containing eight output
channels; column delays align them with activation propagation. The 8x8 array
contains 64 signed 8x8 multipliers, 32-bit wrapping accumulators and sticky PE
overflow. Eight column reductions sum the PE rows. This is a one-spatial-vector
schedule, not a continuously occupied matrix array. Outer loops are OC tile,
spatial position, IC tile. Input activations must be replayed for each OC tile.

Quantization is optional ReLU, arithmetic shift 0..31, signed INT8 zero-point
addition and saturation to [-128,127]. No bias, per-channel multiplier/shift,
convolution address generator, pooling or automatic multilayer engine exists.
Dense and pre-lowered convolution work as matrix multiplication. Software can
chain layers. The hardware channel loops divide by eight (floor): arbitrary
channels are NOT supported without explicit padding. Spatial count is 16 bits.

## Functional findings and blockers (priority order)

1. COMPUTE uses fixed cycles with no activation handshake prerequisite. Late
   data corrupts results; UART cannot feed the array directly at this rate.
2. Descriptor validation is never called. Its helper also omits alignment and
   bank-capacity checks. Address arithmetic truncates excess weight addresses.
3. Output TLAST is derived from STORE_OUTPUT, although output can appear during
   DRAIN. Thus the final beat can be marked incorrectly.
4. DONE is sticky until abort/reset; abort only resets the FSM, leaving potential
   queued output and pipeline state. UART must define repeat-run/reset behavior.
5. No UART, packet integrity/length checking, memory loaders, activation replay,
   output capture, transfer completeness or host software exists.
6. Original testbench samples after rather than at handshake edges and can print
   PASS for incomplete outputs. It has no backpressure/error/invalid-config tests.
7. Counters labelled AXI reads count enabled cycles, not transfers. Bank conflict
   expression is unreachable by construction. Overflow status is not integrated
   into the core error FSM.
8. Linear 8-input 32-bit column sums, asynchronous DSP register resets and wide
   variable address multipliers need timing/resource inspection after synthesis.

Python's tiled model computes real matrix multiplication and appears consistent
for supported dimensions; an independent NumPy INT64 comparison is planned.
Its saturating INT32 overflow differs from wrapping RTL, but K<=512 bounds the
maximum dot product to 8,388,608, far inside INT32. README claims about all
dimensions, 16x16 fitting 240 DSPs (256 > 240), production readiness, 100 MHz,
resources and simulator passes are not accepted as current measurement evidence.
README also targets Arty/CSG324, not Nexys 4 DDR/CSG324-1 with board pin constraints.

## Feasibility before synthesis (estimates, not measured)

XC7A100T: 63,400 LUT, 126,800 FF, 135 RAMB36, 240 DSP48E1. Keep all 64 MACs.
Expect about 64 DSP plus address arithmetic, 4 RAMB36 for the two weight banks
(64-bit-wide, 1024-deep maps to two per bank), and approximately 4 more RAMB36
for 8 KiB activation and 8 KiB output buffers. Packet buffering adds a small
amount. Several thousand LUT/FF are plausible; exact usage requires synthesis.
The full system has ample arithmetic/memory headroom at this capacity. A 512x512
weight matrix does NOT fit the existing memory and will be rejected, not wrapped.

## Incremental implementation plan

1. Save backup; run all ten original cases with XSim 2025.2 and save logs. Add
   independent model comparison and repair testbench pass/handshake checks.
2. Keep MAC array, SRAM and quantizer. Add one-beat activation staging and make
   LOAD_ACT wait for it. Validate descriptors, fix TLAST, reset/abort and counters.
   Test stalls, repeated runs, boundary capacities and malformed descriptors.
3. Add 115200 8N1 UART RX/TX, framed request/response protocol with CRC16, bounded
   payload, sequence echo, timeout recovery and explicit error codes. Stage and
   validate whole packets before applying writes. Only one command is outstanding.
4. Add sequential loading of the inactive weight bank and BRAM activation/output
   buffers; track loaded counts. Replay activation BRAM per OC tile. Hold config
   and memory immutable during inference; permit status and explicit reset.
5. Add Python codec/client/CLI with matching bounds, ordering, retries policy,
   matrix packing/reference and end-to-end UART simulations.
6. Fetch Digilent's official Nexys-4-DDR master XDC, retain provenance, use only
   verified clock/reset/UART pins. Synchronize reset release and UART input.
7. Synthesize, place, route and inspect DRC/utilization/setup/hold timing at
   100 MHz. Fix measured issues; generate bitstream only when gates pass. Save
   reproducible scripts, reports, programming instructions and hardware test list.

Tool discovery: `C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat -version` reports
Vivado v2025.2, build 6299465. XSim tools and Artix-7 device files are installed.
No board is available; USB enumeration, actual UART/electrical operation, JTAG
programming and physical inference remain future hardware acceptance tests.

## Revalidated arrival state and subsequent work

The working tree already contained this audit and partial core fixes. All were
preserved in `backups/audit_resume_20261026.zip` before edits. Every RTL module,
testbench, model/packing function, vector configuration, existing log, constraint
and script was inspected. `core_rst_n` declaration order was the compile error.
After fixing it, all ten cases passed with 792 outputs, input delays and output
backpressure. This supersedes the original README's 784-output count. See
`IMPLEMENTATION_REPORT.md` for subsequent UART integration and measured tool results.

## Completion audit, 2026-10-27

The sections above describe the original development audit, not missing modules
in the current tree. On resuming, the complete UART PHY/parser, command service,
activation/result BRAM, board wrapper, verified XDC, Python client, regression
suite and Vivado build flow were already present. The compute path retains the
64 INT8 MACs, INT32 sums, shift/ReLU/zero-point/saturation quantizer, both weight
banks, 64-bit AXI handshakes and 8 KiB per-tensor limits described above.

The latest documented state was stale: `build/vivado` had actually produced a
bitstream at 100 MHz (WNS +0.044 ns, WHS +0.069 ns), while the report still said
implementation was pending. Two newer build directories did not contain completed
passing manifests. They were not accepted as final evidence. The routed design
used 9,342 LUTs, 5,852 registers, 8 RAMB36 and 69 DSP48E1; resource capacity did not
justify shrinking or rewriting the array.

All fourteen RTL modules, their interfaces, testbenches, software models, test
vectors, host protocol, build scripts, constraints and existing reports were
reviewed. Pin assignments match the retained Digilent master XDC and its recorded
SHA-256. No AGENTS.md was found. Existing uncommitted changes were preserved in
`backups/completion_checkpoint_20261027_115431.zip` before completion edits.

Remaining work was prioritized as follows:

1. Re-run the core, UART PHY, stream contract and complete UART system regressions
   against the current sources; retain actual simulator evidence.
2. Implement the host's documented recovery procedure as an explicit command,
   detect incomplete serial writes, and test fragmented/malformed responses,
   uncertain mutations, chunked tensors and recovery without physical hardware.
3. Verify wrapper watchdog/error reporting and reset/reload using targeted fault
   injection, keeping those tests distinct from unforced numerical inference.
4. Complete a fresh source-hashed Vivado synthesis/place/route build with setup,
   hold, pulse-width, coverage, DRC and routing gates before bitstream generation.
5. Replace the stale implementation status and update reproducible build and
   programming instructions. Preserve warnings and hardware-only acceptance tasks.

No synthesizable RTL, pin assignment, numerical precision, memory capacity or
compute schedule needed changing during this completion pass. Confirmed final
results and remaining hardware limitations are in `IMPLEMENTATION_REPORT.md`.
