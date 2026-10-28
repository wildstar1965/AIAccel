# UART protocol v1

Nexys 4 DDR USB-UART: **115200 baud, 8 data bits, no parity, one stop bit**,
no hardware/software flow control. The 100 MHz clock uses 868 clocks/bit
(115207.37 baud, +0.0064%). FPGA RX is C4 (`UART_TXD_IN`); FPGA TX is D4
(`UART_RXD_OUT`). These signal names describe the USB bridge's direction.

## Framing and transactions

| Byte offset | Size | Value |
|---|---:|---|
| 0 | 2 | `55 AA` sync |
| 2 | 1 | Version = 1 |
| 3 | 1 | Command; response = command OR `80` hex |
| 4 | 1 | Host sequence, echoed by FPGA |
| 5 | 2 | Payload byte length, little endian, 0..256 |
| 7 | length | Payload |
| 7 + length | 2 | CRC-16/CCITT-FALSE, little endian |

CRC covers version, command, sequence, both length bytes and payload. Polynomial
0x1021, initial 0xFFFF, no reflection, no final XOR. Standard `123456789` check:
0x29B1. Python uses `binascii.crc_hqx(body, 0xffff)`.

One request may be outstanding. Wait for its complete response before sending the
next. Sequence numbers distinguish responses and wrap modulo 256; the device does
not cache responses or enforce monotonic sequence numbers. Bytes sent while a
command/response is in progress are ignored. This is not a pipelined link.

Every response payload begins with one status byte: zero means success, nonzero
means rejection. Additional bytes depend on the command. Transfer acknowledgements
are issued after all accepted words are written. CRC/length checks precede command
execution; invalid packets cannot partially write a tensor.

A partial packet times out after 100 ms without a byte. A framing error during a
partial packet rejects it. If command/sequence have not arrived, their response
values are zero. Oversized lengths are rejected immediately; trailing bytes during
the response are discarded. After an uncertain link failure, stop transmitting,
wait at least 150 ms for parser recovery, drain the host receive buffer, issue
RESET, and reload configuration/tensors. Do not blindly retry START or writes:
sequence echo alone does not give exactly-once execution.

The host implements that recovery as `Device.recover()` and
`python host/accelerator.py --port COM5 recover`. It flushes queued transmission,
waits 150 ms, drains stale received bytes, then requires a RESET acknowledgement.
A short host write is reported as a failed transaction; it is never silently
accepted or automatically retried.

## Commands

All integers below are little endian. Signed values use two's complement.

| ID hex | Name | Request payload | Successful response after status |
|---|---|---|---|
| 01 | PING | Empty | `41 49 38 01 00 04 08 08`: AI8, protocol 1, capacity 1024 words, array 8x8 |
| 02 | STATUS | Empty | 24-byte snapshot described below |
| 10 | CONFIG | K:u16, N:u16, M:u16, shift:u8, zero-point:i8, ReLU:u8 | Empty |
| 11 | WEIGHTS | Word offset:u16, 1..31 words of 8 bytes | Empty |
| 12 | ACTIVATIONS | Word offset:u16, 1..31 words of 8 bytes | Empty |
| 13 | START | Empty | Empty; execution is asynchronous |
| 14 | READ | Word offset:u16, word count:u8 (1..31) | Requested result words |
| 15 | RESET | Empty | Empty; aborts inference, clears configuration/completeness/results |

CONFIG describes `Y[M,N] = A[M,K] * W[K,N]`. K and N are multiples of 8,
8..512. M is positive and fits u16. **K*N, M*K, M*N must each be <=8192**.
Shift is 0..31; ReLU must be 0 or 1. No bias or per-channel scaling is supported.
Pad dimensions explicitly in software if needed and check the padded capacities.

Successful CONFIG invalidates both transfer counts and previous results; rejected
CONFIG leaves existing data/configuration unchanged. Each loader requires the
offset to equal its current loaded-word count, starting at zero. Holes, duplicate
offsets, excess data and partial words are rejected. START requires all configured
weights and activations to be loaded. During inference only PING, STATUS and RESET
are accepted. READ requires successful completion. Repeated START after completion
reuses the loaded weights and activations. Reconfigure to load a different tensor.

The wrapper holds the core in reset while idle, so bank 1 is always the inactive
weight destination. START releases reset and the existing FSM swaps to bank 1.
Completion/error asserts core reset again while preserving memory contents.
Result validity is tracked separately; reset never requires clearing BRAM bits.

## Tensor order and arithmetic

Each word's byte zero occupies bits 7:0. Weight word address is
`(output_tile*K + input_channel)`; byte c holds `W[input_channel, output_tile*8+c]`.
Activation words are row major: spatial position, input tile, eight channels.
Only one activation copy is uploaded; the wrapper replays it per output tile.
Result words are output tile, spatial position, eight output channels. The Python
client restores row-major `[M,N]` results.

All inputs/weights are signed INT8. Products accumulate in 32-bit registers;
the supported K<=512 bounds every dot product within INT32. Results are:
`saturate_int8((optional_relu(dot_product) >>> shift) + zero_point)`.
The arithmetic right shift rounds negative values toward minus infinity. This is
a specific shift-only quantizer, not a general TFLite/ONNX quantization engine.

## STATUS data (offsets exclude response status byte)

| Offset | Type | Meaning |
|---:|---|---|
| 0 | u8 | Flags: bit0 running, bit1 completed, bit2 configured, bit3 weights ready, bit4 activations ready |
| 1 | u8 | Reserved, zero |
| 2 | u8 | Sticky inference error |
| 3 | u8 | Core FSM state (zero while core held reset) |
| 4 | u16 | Loaded weight words |
| 6 | u16 | Loaded activation words |
| 8 | u16 | Captured result words |
| 10 | u16 | Required weight words |
| 12 | u16 | Required activation words |
| 14 | u16 | Required result words |
| 16 | u32 | Current/last inference cycles at 100 MHz |
| 20 | u32 | Rejected transport packets since physical reset (CRC/version/length/timeout/framing) |

Completed is sticky until START/CONFIG/RESET. This is a poll protocol; there is no
unsolicited completion packet. STATUS is a coherent snapshot at command execution.

## Errors

| Status | Meaning |
|---:|---|
| 1 | CRC mismatch |
| 2 | Bad packet or command payload length |
| 3 | Unsupported protocol version |
| 4 | Inference busy |
| 5 | Invalid layer configuration or capacity |
| 6 | Address, sequential-loading or read-range error |
| 7 | Missing configuration/data or results not ready |
| 8 | Unknown command |
| 9 | Partial packet timeout |
| 10 | UART framing error during a packet |

Inference errors in STATUS are separate: `0x10 | core_error_code`, `0x20`
arithmetic overflow, `0x21` one-second wrapper watchdog, `0x22` result count,
TKEEP/TLAST or activation replay mismatch. The core state watchdog is 100,000
cycles (1 ms). Any inference error makes results unavailable; RESET then reload
is the supported recovery. Input data and errors are observable through protocol
responses; internal AXI and debug signals are not physical pins.
