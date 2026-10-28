# FPGA INT8 inference accelerator — Nexys 4 DDR

A SystemVerilog 8×8 MAC accelerator with a complete UART control/data path for the
Digilent Nexys 4 DDR, **XC7A100T-CSG324-1**, using Vivado 2025.2 on Windows.
The PC can configure a layer, load weights and activations, start inference, poll
status, retrieve results, and abort/reset. No physical board was available during
development; simulation and implementation results are distinguished from future
hardware acceptance tests.

## Architecture

```text
USB-UART -> RX -> CRC packet parser -> command/descriptor controller
                                        | weights -> dual-bank SRAM
                                        | activation BRAM -> replay -> AXI input
                                        |                              |
                                        |                         8x8 INT8 MACs
                                        |                              |
                                        |                     column sum + quantize
                                        |                              |
USB-UART <- TX <- response packets <- result BRAM <--------------- AXI output
```

The compute core retains all 64 signed INT8 multipliers and 32-bit accumulators.
It implements matrix multiplication followed by optional ReLU, arithmetic right
shift, signed zero-point addition and INT8 saturation. Dense layers and externally
lowered convolutions are supported; bias, general per-channel rescaling, pooling,
DDR2 access and an autonomous multilayer graph engine are not implemented.
The Python API can execute layers sequentially on the PC.

K/N are multiples of 8 in 8..512. The UART system has **8 KiB each for layer weights,
activations and results**; every tensor must fit. Both original weight banks are
retained. The core streams one spatial vector per tile and replays activations
per output tile; 64 instantiated MACs do not imply 64 useful MACs every cycle.
No activation precision, PE count or existing weight capacity was reduced.

Verified on 2026-10-27 with Vivado 2025.2: **100 MHz timing closure**
(setup +0.112 ns, hold +0.064 ns), 9,333 LUTs, 5,852 registers, 8 BRAMs and 69 DSPs.
The delivered bitstream is
[`build/release_20261027_full/nexys4ddr_top.bit`](build/release_20261027_full/nexys4ddr_top.bit).
Core, UART, recovery and Python regressions pass; physical-board acceptance remains.

## Verification and use

- [Architecture audit and implementation plan](docs/AUDIT.md)
- [Measured verification/implementation report](docs/IMPLEMENTATION_REPORT.md)
- [Build, programming and hardware acceptance instructions](docs/BUILD_AND_HARDWARE.md)
- [UART commands, packet format, memory layout and errors](docs/UART_PROTOCOL.md)
- [Python host client](host/accelerator.py) and [example tensor](host/example.json)

```powershell
python -m unittest discover -s verification -p test_host.py -v
python scripts/regress.py --output build/core_regression
python scripts/verify_units.py
python scripts/verify_system.py
python scripts/build.py --output build/my_vivado_run
```

Choose an empty build output directory; the Python runner preserves earlier runs
and records SHA-256 hashes of the sources, reports, checkpoints and bitstream.
The build checks setup/hold/pulse-width slack, timing coverage, DRC errors and
unrouted nets before bitstream generation. It does not waive timing failures or
lower DRC severities. Only four
physical pins are exposed: oscillator, reset, UART RX and UART TX, using Digilent's
official board assignments.

With a programmed board and its COM port identified:

```powershell
python -m pip install -r host/requirements.txt
python host/accelerator.py --port COM5 ping
python host/accelerator.py --port COM5 demo
```

After an interrupted transfer, run `python host/accelerator.py --port COM5 recover`
before reloading tensors. This drains stale replies and performs an explicit reset;
the client never automatically retries a potentially executed write or START.

The earlier Arty-specific README and pre-existing workspace files are preserved
in the local backup archives. Its historical timing/resource claims are not
treated as results for this design.
