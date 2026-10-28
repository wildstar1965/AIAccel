"""Nexys 4 DDR INT8 accelerator: protocol codec, serial client, and JSON CLI."""
from __future__ import annotations

import argparse
import binascii
from dataclasses import dataclass
import json
from pathlib import Path
import struct
import time

SYNC = b'\x55\xaa'
PING, STATUS, CONFIG, WEIGHTS, ACTIVATIONS, START, READ, RESET = 1, 2, 16, 17, 18, 19, 20, 21
ERRORS = {1: 'CRC mismatch', 2: 'invalid length', 3: 'unsupported version',
          4: 'inference busy', 5: 'invalid configuration', 6: 'address/order error',
          7: 'not ready', 8: 'unknown command', 9: 'packet timeout', 10: 'UART framing error'}


def frame(command: int, sequence: int, payload: bytes = b'') -> bytes:
    if not 0 <= command <= 255 or not 0 <= sequence <= 255 or len(payload) > 256:
        raise ValueError('invalid command, sequence, or payload size')
    body = struct.pack('<BBBH', 1, command, sequence, len(payload)) + payload
    return SYNC + body + struct.pack('<H', binascii.crc_hqx(body, 0xffff))


def decode(packet: bytes) -> tuple[int, int, bytes]:
    if len(packet) < 9 or packet[:2] != SYNC:
        raise ValueError('invalid frame')
    version, command, sequence, size = struct.unpack('<BBBH', packet[2:7])
    if version != 1 or size > 256 or len(packet) != size + 9:
        raise ValueError('invalid version or length')
    if binascii.crc_hqx(packet[2:-2], 0xffff) != int.from_bytes(packet[-2:], 'little'):
        raise ValueError('CRC mismatch')
    return command, sequence, packet[7:-2]


@dataclass(frozen=True)
class Config:
    k: int
    n: int
    m: int
    shift: int = 0
    zero_point: int = 0
    relu: bool = False

    def validate(self):
        if any(type(x) is not int for x in (self.k, self.n, self.m, self.shift, self.zero_point)):
            raise ValueError('dimensions and quantization values must be integers')
        if not (8 <= self.k <= 512 and 8 <= self.n <= 512 and
                self.k % 8 == self.n % 8 == 0 and 1 <= self.m <= 65535):
            raise ValueError('K/N must be multiples of 8 in 8..512; M must be positive')
        if max(self.k*self.n, self.k*self.m, self.n*self.m) > 8192:
            raise ValueError('each tensor must fit its 8192-byte memory')
        if not 0 <= self.shift <= 31 or not -128 <= self.zero_point <= 127 or type(self.relu) is not bool:
            raise ValueError('invalid shift, zero-point, or ReLU flag')

    def pack(self) -> bytes:
        self.validate()
        return struct.pack('<HHHBbB', self.k, self.n, self.m, self.shift, self.zero_point, self.relu)


def matrix(value, rows, cols):
    if len(value) != rows or any(len(row) != cols for row in value):
        raise ValueError(f'expected matrix shape {rows}x{cols}')
    if any(type(x) is not int or not -128 <= x <= 127 for row in value for x in row):
        raise ValueError('tensor entries must be signed INT8 integers')
    return value


def pack_weights(weights, cfg: Config) -> bytes:
    cfg.validate()
    matrix(weights, cfg.k, cfg.n)
    return bytes(weights[k][n+c] & 255 for n in range(0, cfg.n, 8)
                 for k in range(cfg.k) for c in range(8))


def pack_activations(activations, cfg: Config) -> bytes:
    cfg.validate()
    matrix(activations, cfg.m, cfg.k)
    return bytes(x & 255 for row in activations for x in row)


def unpack_results(raw: bytes, cfg: Config):
    if len(raw) != cfg.m*cfg.n:
        raise ValueError('incomplete output tensor')
    values = struct.unpack(f'{len(raw)}b', raw)
    result = [[0]*cfg.n for _ in range(cfg.m)]
    cursor = 0
    for n in range(0, cfg.n, 8):
        for m in range(cfg.m):
            result[m][n:n+8] = values[cursor:cursor+8]
            cursor += 8
    return result


def reference(activations, weights, cfg: Config):
    """Independent scalar matrix product using unbounded Python integers."""
    cfg.validate()
    matrix(activations, cfg.m, cfg.k)
    matrix(weights, cfg.k, cfg.n)
    result = []
    for row in activations:
        output = []
        for n in range(cfg.n):
            acc = sum(row[k]*weights[k][n] for k in range(cfg.k))
            if cfg.relu:
                acc = max(0, acc)
            output.append(max(-128, min(127, (acc >> cfg.shift)+cfg.zero_point)))
        result.append(output)
    return result


def parse_status(data: bytes) -> dict:
    if len(data) != 24:
        raise ValueError('invalid status response')
    flags, _, error, state, wl, al, count, wn, an, rn, cycles, rejected = struct.unpack('<BBBB6HII', data)
    return dict(running=bool(flags & 1), done=bool(flags & 2), configured=bool(flags & 4),
                weights_ready=bool(flags & 8), activations_ready=bool(flags & 16),
                error=error, core_state=state, weights_loaded=wl, activations_loaded=al,
                results_count=count, weights_needed=wn, activations_needed=an,
                results_needed=rn, cycles=cycles, rejected_packets=rejected)


class Device:
    def __init__(self, port: str, baud: int = 115200, timeout: float = 3.0):
        import serial  # Only the real serial client requires pyserial.
        self.serial = serial.Serial(port, baud, timeout=0.05, write_timeout=timeout,
                                    bytesize=8, parity='N', stopbits=1,
                                    rtscts=False, dsrdtr=False, xonxoff=False)
        self.timeout = timeout
        self.sequence = 0

    def close(self):
        self.serial.close()

    def command(self, command, payload=b'') -> bytes:
        sequence = self.sequence
        self.sequence = (sequence+1) & 255
        packet = frame(command, sequence, payload)
        if self.serial.write(packet) != len(packet):
            raise TimeoutError('Incomplete request write; recover/reset and reload before continuing.')
        deadline = time.monotonic()+self.timeout
        buffer = bytearray()
        while time.monotonic() < deadline:
            buffer.extend(self.serial.read(max(1, self.serial.in_waiting)))
            while len(buffer) >= 2 and buffer[:2] != SYNC:
                del buffer[0]
            if len(buffer) >= 7:
                size = int.from_bytes(buffer[5:7], 'little')
                if size > 256:
                    raise RuntimeError('response length exceeds protocol limit')
                if len(buffer) >= size+9:
                    cmd, seq, response = decode(bytes(buffer[:size+9]))
                    if cmd != command | 128 or seq != sequence or not response:
                        raise RuntimeError('unexpected response transaction')
                    if response[0]:
                        raise RuntimeError(ERRORS.get(response[0], f'device error {response[0]}'))
                    return response[1:]
        raise TimeoutError('No valid response; do not blindly retry mutations. Reconnect/reset and reload.')

    def status(self):
        return parse_status(self.command(STATUS))

    def recover(self):
        """Explicitly abandon an uncertain transaction, reset, then allow reload.

        The parser expires partial packets after 100 ms. Wait 150 ms after all
        queued output has left, then discard any stale acknowledgement. This is
        deliberately separate from command(): mutations are never retried.
        """
        self.serial.flush()
        time.sleep(0.150)
        self.serial.reset_input_buffer()
        self.command(RESET)

    def load(self, command, data):
        if command not in (WEIGHTS, ACTIVATIONS) or not data or len(data) % 8:
            raise ValueError('load needs whole 64-bit words')
        for offset in range(0, len(data), 248):
            self.command(command, struct.pack('<H', offset//8)+data[offset:offset+248])

    def infer(self, activations, weights, cfg: Config, timeout=5.0):
        packed_w = pack_weights(weights, cfg)
        packed_a = pack_activations(activations, cfg)
        self.command(CONFIG, cfg.pack())
        self.load(WEIGHTS, packed_w)
        self.load(ACTIVATIONS, packed_a)
        status = self.status()
        if not status['weights_ready'] or not status['activations_ready']:
            raise RuntimeError(f'incomplete load: {status}')
        self.command(START)
        deadline = time.monotonic()+timeout
        while True:
            status = self.status()
            if status['error']:
                raise RuntimeError(f'inference failed: {status}')
            if status['done']:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(f'inference completion timeout: {status}')
            time.sleep(0.01)
        raw = bytearray()
        for offset in range(0, cfg.m*cfg.n//8, 31):
            count = min(31, cfg.m*cfg.n//8-offset)
            raw.extend(self.command(READ, struct.pack('<HB', offset, count)))
        return unpack_results(bytes(raw), cfg)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, help='Windows COM port, e.g. COM5')
    parser.add_argument('action', choices=['ping', 'status', 'reset', 'recover', 'infer', 'demo'])
    parser.add_argument('--input', type=Path, help='JSON with activations, weights, shift, zero_point, relu')
    parser.add_argument('--output', type=Path, help='save output tensor as JSON')
    args = parser.parse_args()
    dev = Device(args.port)
    try:
        if args.action == 'ping':
            print(dev.command(PING).hex())
        elif args.action == 'status':
            print(json.dumps(dev.status(), indent=2))
        elif args.action == 'reset':
            dev.command(RESET)
            print('Reset acknowledged')
        elif args.action == 'recover':
            dev.recover()
            print('Recovery reset acknowledged; reload configuration and tensors')
        else:
            if args.action == 'demo':
                data = dict(activations=[[1,-2,3,-4,5,-6,7,-8]],
                            weights=[[int(i==j) for j in range(8)] for i in range(8)])
            else:
                if args.input is None:
                    parser.error('infer requires --input')
                data = json.loads(args.input.read_text())
            act, wgt = data['activations'], data['weights']
            cfg = Config(len(wgt), len(wgt[0]), len(act), data.get('shift', 0),
                         data.get('zero_point', 0), data.get('relu', False))
            result = dev.infer(act, wgt, cfg)
            if result != reference(act, wgt, cfg):
                raise RuntimeError('FPGA result differs from software reference')
            text = json.dumps(result)
            print(text)
            print('All outputs match software reference')
            if args.output:
                args.output.write_text(text+'\n')
    finally:
        dev.close()


if __name__ == '__main__':
    main()
