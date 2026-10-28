# Reproduce on Windows with Vivado 2025.2

Run PowerShell in the repository root. No board is needed for simulation or build.
Vivado is installed here at `C:/AMDDesignTools/2025.2/Vivado/bin`; adapt paths if
your installation differs. Full Vivado may need normal user-profile write access
to initialize its Tcl application support. Do not suppress design checks.

```powershell
python -m unittest discover -s verification -p test_host.py -v
python scripts/regress.py --output build/core_regression
python scripts/verify_units.py
python scripts/verify_system.py
python scripts/build.py --output build/my_vivado_run
```

Use Python 3.10 or later. `build/my_vivado_run` must be empty; use a new name for
each build. The runner writes `manifest.json`, hashes the exact input sources and
output reports/checkpoints/bitstream, and fails if sources change during the run.
For another installation, pass `--vivado-bin` to the build and all regression
runners. The unit runner also accepts `--top tb_uart_faults` (or another unit
testbench name) to run a targeted check.

Simulation logs are in `build/core_regression`, `build/tb_uart_phy`,
`build/tb_core_contract`, `build/tb_uart_faults`, `build/byte_system` and
`build/serial_system`. The system runner decodes all original stored vectors
and compares them to a separate scalar Python matrix product before simulating.
It adds full-capacity and signed/quantized cases. No NumPy or serial package is
needed for these new runners; the original `verification/scripts` generators use
NumPy (`python -m pip install numpy` if regenerating those vectors).

The build is a reproducible non-project Tcl flow: read RTL/XDC, synthesize the
four-port `nexys4ddr_top` for `xc7a100tcsg324-1`, optimize, place, physical-optimize,
route, report utilization/timing/DRC/CDC/methodology, then generate a bitstream only
if setup, hold, pulse width, timing coverage, routing and DRC gates pass. Outputs
go to the specified build directory. Open its `routed.dcp` in Vivado to inspect
the complete implemented design. The direct Tcl flow remains available:

```powershell
New-Item -ItemType Directory -Force build/manual_run | Out-Null
& C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat -mode batch -source scripts/build_vivado.tcl -log build/manual_run/vivado.log -journal build/manual_run/vivado.jou -tclargs build/manual_run
```

The direct Tcl command does not create a hash manifest; prefer `scripts/build.py`
for delivery builds. The delivered build location and measured results are in
`docs/IMPLEMENTATION_REPORT.md`.

The completed delivery is `build/release_20261027_full/nexys4ddr_top.bit` with
`passed: true` in the adjacent `manifest.json`. Its reports/checkpoints and source
hashes were checked after the build. `build/completion_verification/manifest.json`
records the final simulation evidence. These local artifacts are Git-ignored;
copy the build directories as well as the source tree when transferring delivery.

Board pin provenance: [Digilent Nexys-4-DDR master XDC](https://github.com/Digilent/digilent-xdc/blob/master/Nexys-4-DDR-Master.xdc),
Rev. C. Pins E3 clock, C12 active-low CPU reset, C4 RX and D4 TX were checked against
the official source on 2026-10-26. The retained `docs/Nexys-4-DDR-Master.xdc` SHA256 is
`36B0DD2332991699F478F430F0F01ADD968FF375C65C6D76A301E864FFB70572`.
Only `constraints/nexys4ddr.xdc` is active. DDR2, switches and LEDs are not used.

## Programming when the board is available

1. Connect/power the Nexys 4 DDR through its USB programming/UART connection.
   Confirm the physical board/device matches the target, and install Digilent/FTDI
   cable drivers if Windows does not enumerate JTAG and a COM port.
2. In Vivado Hardware Manager: Open Target -> Auto Connect. Select the XC7A100T,
   Program Device, and choose `nexys4ddr_top.bit` from the verified build directory
   listed in the implementation report (or your own passing build). No ILA probes file
   is required. This programs volatile configuration; this project does not write
   configuration flash.
3. Press/release CPU RESET, identify the COM port in Windows Device Manager, and
   run the host commands below (replace COM5 with the actual port).

```powershell
python -m pip install -r host/requirements.txt
python host/accelerator.py --port COM5 ping
python host/accelerator.py --port COM5 status
python host/accelerator.py --port COM5 demo
python host/accelerator.py --port COM5 infer --input host/example.json --output build/result.json
python host/accelerator.py --port COM5 reset
python host/accelerator.py --port COM5 recover
```

The CLI validates inputs before transferring them, checks transfer readiness,
polls completion, reconstructs output tensors, and compares every output with the
independent software reference. Arbitrary layers can be supplied as JSON with
`activations`, `weights`, `shift`, `zero_point`, and `relu`. Shapes determine M/K/N.
Use the Python `Device` API to chain layers on the PC, explicitly requantizing and
padding as appropriate. There is no autonomous on-FPGA multilayer graph executor.

Use `recover` after a timeout, partial write, unplug/reconnect, or uncertain reply.
It waits for queued transmission to finish, waits 150 ms for parser timeout,
discards stale received bytes, and sends RESET. An acknowledged recovery clears
configuration/results; rerun `infer` or `demo` to reload everything. A failed
recovery requires checking the COM port, cable and board reset. No command is
automatically retried.

## Physical acceptance still required

Hardware availability is required to confirm programming, clock/reset electrical
behavior, USB-UART enumeration/baud reliability, and real FPGA outputs. Run identity,
random signed, quantization, full-capacity, repeated-run, reset-during-run, and
interrupted-transfer recovery tests on the board. Compare every tensor with the
host reference. Test sustained transfers and reconnect/reset, then measure actual
wall-clock latency and throughput (UART dominates bulk transfer time).
Simulation and routed timing reports do not constitute a physical inference demo.
