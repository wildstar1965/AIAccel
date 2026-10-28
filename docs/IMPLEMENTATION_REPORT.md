# Implementation and verification report — 2026-10-27

Target: Nexys 4 DDR, XC7A100T-CSG324-1, Vivado/XSim 2025.2, 100 MHz, UART 115200 8N1.
No FPGA board is available. This report distinguishes tool evidence from hardware
acceptance, which remains outstanding.

**Completion status:** all listed simulation regressions pass, and a fresh Vivado
2025.2 synthesis/place/route build passes the timing, coverage, DRC and routing
gates and generates the bitstream. No physical FPGA inference is claimed.

## Original implementation and checkpoints

Existing Git HEAD was `958afe9`, with five modified RTL/TB files and untracked
audit, scripts and vectors already present. These were inspected and preserved.
`backups/audit_resume_20261026.zip` captures the arrival workspace before edits.
The earlier `backups/pre_uart_20261026.zip` also remains intact.
`docs/AUDIT.md` records the architecture and priorities established before the
UART implementation. There was no board top or reproducible board build initially.

Baseline logs existed, but the modified working tree initially failed XSim
compilation because `core_rst_n` was used before its declaration. That declaration
was moved. Existing staging, descriptor, TKEEP, TLAST and counter fixes were retained
and verified against the actual RTL rather than assumed correct.

## Phase results and changed files

| Phase | Deliverables / changed files | Evidence and next action |
|---|---|---|
| 1 Audit | `docs/AUDIT.md`; backup archive | Read all RTL, TB, models, vectors, Git diff and logs; identified missing UART/buffers/board top |
| 2 Feasibility | First synthesis/routing reports | All 64 MACs retained; 8 BRAMs and 69 DSPs measured; first route failed timing, requiring wrapper fixes |
| 3 UART/host | `rtl/uart_rx.sv`, `uart_tx.sv`, `uart_packet.sv`, `host/`, protocol documentation | CRC, bounded lengths, transaction errors and host reference tested |
| 4 Integration | `rtl/accelerator_uart_service.sv`, `nexys4ddr_top.sv`; core declaration fix | BRAM replay/capture, readiness, busy protection, repeated runs and abort verified |
| 5 Verification | Three new testbenches, `scripts/verify_*`, `system_vectors.py`, `verification/test_host.py` | Actual XSim and Python results below |
| 6 Implementation | `constraints/nexys4ddr.xdc`, `scripts/build_vivado.tcl` | Iterative synthesis/place/route; final result below |
| 7 Delivery | README, protocol, this report, build/hardware guide, example JSON | Physical programming/UART/inference acceptance remains future work |

## Completion pass: 2026-10-27

The arrival tree already contained the full accelerator/UART integration and an
older successful bitstream. The newer hash-recorded build had been interrupted,
and this report incorrectly still called implementation pending. The completion
audit is appended to `AUDIT.md`. The working tree was preserved before edits in
`backups/completion_checkpoint_20261027_115431.zip`; earlier archives remain intact.

No synthesizable RTL, XDC pin/clock constraint, PE count, precision or memory
capacity was changed during this pass. Completion changes are:

- `host/accelerator.py`: explicit `recover` command/API (flush, 150 ms parser
  recovery, receive drain, acknowledged RESET), plus detection of partial writes.
- `verification/test_host.py`: seven additional serial-client tests, including
  fragmented/noisy responses, sequence wrap, malformed replies, no automatic
  START retry, partial writes, recovery and chunked end-to-end client execution.
- `tb/tb_uart_faults.sv`: transport timeout/framing recovery and wrapper fault
  reporting, reset/reload and subsequent unforced identity inference.
- `scripts/verify_units.py`: the new testbench in the default suite, selectable
  `--top`, and configurable `--vivado-bin`/`VIVADO_BIN`.
- README, audit, protocol, build/hardware guide and this report: current commands,
  source/artifact hashes, measured results and remaining hardware checks.

## Commands executed and confirmed results

| Command | Confirmed result | Logs |
|---|---|---|
| `python scripts/regress.py --output build/completion_core` | 10/10 pass; **792/792** scalar outputs, delayed inputs and output stalls | `build/completion_core/results.json`, per-test logs |
| `python scripts/verify_system.py` | **428** byte-level and **31** serial-pin transactions pass | `build/byte_system/simulation.log`, `build/serial_system/simulation.log` |
| `python scripts/verify_units.py` | UART PHY, core contract and UART faults pass; **58** fault/recovery transactions | `build/tb_uart_phy/simulation.log`, `build/tb_core_contract/simulation.log`, `build/tb_uart_faults/simulation.log` |
| `python -m unittest discover -s verification -p test_host.py -v` | **10/10** Python tests pass | `build/completion_verification/host_tests.log` |
| `python scripts/build.py --output build/release_20261027_full` | Fresh synthesis/place/route/bitstream build; final gates below | `build/release_20261027_full/manifest.json`, `console.log` and reports |

The original ten test cases sum to 792 outputs, not the earlier README's 784.
The byte-system test compares 17,640 scalar result bytes, including an identity
repeat. It decodes original vectors and checks expected values against independent
Python integer dot products. Added cases: K512/N16/M16, K16/N512/M16,
K8/N8/M1024, K24/N40/M5 with signed data and quantization. The first three exercise
exact memory capacity boundaries. Responses are checked for command/sequence,
length, status, CRC and data; variable latency/cumulative counter fields are masked.

Negative tests cover bad CRC (including writes), unsupported version, packet
timeout, oversized/invalid lengths, unaligned/zero/oversize dimensions, invalid
quantization, incomplete loads, skipped/duplicate write offsets, read ranges,
unknown commands, mutation/read requests during inference, status while busy,
reset during inference and repeated execution.

UART unit simulation uses the actual 868-cycle divisor: 257 received bytes,
256 transmitted bytes, all byte patterns, ±2% baud mismatch, false start, bad
stop and break recovery. The serial system test uses divisor 16 for speed while
exercising the complete board wrapper and bit-level framing. Core unit checks
include five invalid descriptors, descriptor/weight/activation watchdogs, TKEEP
zero masking, 53-cycle input delay, 100-cycle stable output stall, and abort
flushing that queued output.

The added service test verifies error 10 after a partial-header framing error,
error 9 after an incomplete sync, recovery to a valid PING, full 256-byte transport
payload handling, bad command lengths, and wrapper watchdog error 0x21 after
withholding activations. Explicit fault injection verifies errors 0x20 (overflow),
0x11 (core watchdog), and 0x22 (bad output metadata/premature completion), blocked
result reads, reset clearing status/readiness, and a successful reloaded identity
inference. Overflow is injected because valid K<=512 INT8 dot products cannot
overflow INT32. These tests do not claim naturally occurring arithmetic faults.
An initial testbench run retained a forced overflow variable in XSim; restoring
idle values before releasing injections fixed the testbench, without RTL edits.

## Implementation iterations

Vivado initially failed before reading the build script with `Common 17-356`
(user-app support initialization denied in the sandbox). Normal user-profile
permissions resolved this. Synthesis and implementation completed successfully.

First complete route: 10,697 synthesized LUTs, 7,912 FFs, 8 RAMB36, 69 DSPs;
WNS -7.954 ns, WHS +0.075 ns, zero DRC errors, zero unrouted nets. **No bitstream
was generated.** Reports/RTL are in `backups/first_routed_20261026.zip`.
The main internal failure was the response buffer becoming registers with large
fanout. It was changed to a single explicit write-port RAM template. UART TX was
registered to eliminate its combinational output mux. The provisional synchronous
PC-facing output delay was replaced with an asynchronous 10 ns register-to-pad
maximum delay, under 0.12% of a bit period; internal timing remains at 100 MHz.
An intermediate synthesis confirmed that merely moving memory writes out of reset
was insufficient, and was stopped after the RAM inference warning. The explicit
single-port form was subsequently simulated successfully and sent to Vivado.

## Final implementation

The delivery build completed on **2026-10-27 at 12:06 IST**, with process exit code
zero, using `python scripts/build.py --output build/release_20261027_full`.
The first attempt in `build/release_20261027` failed during sandboxed Vivado
user-app initialization (`Common 17-356`), before reading the design. The successful
run used normal user permissions. No design checks or constraint severities were
disabled to obtain this result.

| Metric | Actual routed result |
|---|---:|
| Part | XC7A100T-CSG324-1 |
| Clock | 100 MHz / 10.000 ns |
| Slice LUTs | 9,333 / 63,400 (14.72%) |
| Slice registers | 5,852 / 126,800 (4.62%) |
| RAMB36 | 8 / 135 (5.93%) |
| DSP48E1 | 69 / 240 (28.75%) |
| Bonded I/O | 4 / 210 (1.90%) |
| Setup WNS / TNS | +0.112 ns / 0.000 ns |
| Hold WHS / THS | +0.064 ns / 0.000 ns |
| Pulse-width WPWS / TPWS | +3.750 ns / 0.000 ns |
| Setup / hold / pulse-width failing endpoints | 0 / 0 / 0 |
| DRC errors | 0 |
| Routable / fully routed nets | 12,556 / 12,556 |
| Routing errors / unrouted nets | 0 / 0 |
| Bitstream generation | Passed |

The limiting setup path runs from PE row 7/column 0's accumulator through the
column reduction to quantizer stage 1: 9.675 ns data delay, 15 logic levels.
The positive setup margin is small; it supports the constrained 100 MHz build,
not an overclocking claim. The UART register-to-pad path is 4.028 ns against its
10 ns asynchronous max-delay bound (+5.972 ns slack). Internal timing remains
constrained at 100 MHz.

`timing_routed.rpt` confirms no unclocked registers, constant-clock problems,
unconstrained internal endpoints, combinational/latch loops or failing pulse-width
checks. The two asynchronous inputs are the intentional CPU reset and UART RX
exceptions. `cdc.rpt` reports two safe endpoints, zero unsafe/unknown endpoints;
the board reset-release and RX synchronizers retain their ASYNC_REG attributes.

Delivery artifacts (paths relative to the repository root):

- **Bitstream:** `build/release_20261027_full/nexys4ddr_top.bit`.
- **Implemented design:** `build/release_20261027_full/routed.dcp`.
- **Reports:** `build/release_20261027_full/{utilization_routed,timing_routed,critical_paths,route_status,drc,methodology,cdc,uart_output_timing}.rpt`.
- **Build evidence:** `build/release_20261027_full/manifest.json`, `result.txt`,
  `console.log`; manifest says `passed: true`, `sources_unchanged: true`.
- **Simulation evidence:** `build/completion_verification/manifest.json`,
  `host_tests.log`, `unit_runner.log`, and the per-test logs listed above.

All **17 build-source hashes and 13 report/checkpoint/bitstream hashes** were
rechecked against the final files. The verification manifest records the test
counts, relevant source hashes and log hashes. The bitstream SHA-256 is:

```text
8e24543fd39d55c4eed99adbf926117660b9ba004ef211d282633f4e6a05372b
```

The earlier `build/vivado` bitstream (+0.044 ns WNS) remains historical evidence;
the delivery build above supersedes it. Build directories, logs and backups are
Git-ignored local artifacts; retain them when moving or archiving the project.

### Warnings retained and reviewed

Zero DRC errors does not mean zero warnings. DRC reports 304 warning entries:
DPIP-1 (139), DPOP-1 (69), DPOP-2 (69), RBOR-1 (6), REQP-1839 (20 shown),
and CHECK-3 (1, the tool's default per-rule reporting limit). Methodology reports
DPIR-1 (3,230), LUTAR-1 (2), and SYNTH-6 (8). No waivers were introduced.

DSP/BRAM pipeline warnings reflect registers remaining in fabric, including the
existing asynchronous-reset MAC pipelines; the actual routed setup/hold checks
still pass. REQP-1839 warns about asynchronous-reset registers driving BRAM
controls. Physical reset invalidates configuration and transfer counts, so all
tensors must be reloaded afterward. LUTAR-1 flags the existing combination of
board reset and core abort/idle reset; functional tests cover abort and repeated
execution, while electrical reset behavior remains a hardware acceptance item.
These warnings and the narrow timing margin are recorded rather than hidden.

## Scope and hardware limitations

The retained core still supports its streamed spatial interface; the UART system's
8 KiB activation/output buffers add explicit capacity limits for autonomous
execution. BRAM buffering eliminates UART starvation/replay loss without reducing
MAC count, precision or weight-bank capacity. It costs four BRAMs beyond the existing
four weight BRAMs. Both weight banks remain, though the UART session uses bank 1
for each run and disallows overlapping loads.

No general model importer, bias/per-channel scale engine, pooling, convolution
lowering, DDR2 controller or hardware multilayer scheduler is claimed. Software
must prepare supported INT8 tensors/quantization and can chain layers. CRC detects
corruption; it is not authentication. No board inference, power measurement,
physical throughput measurement or reliability test has been performed.
See `docs/BUILD_AND_HARDWARE.md` for exact future checks.
