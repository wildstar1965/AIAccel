import binascii
from pathlib import Path
import random
import sys
import struct
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from accelerator import Config, frame, decode, pack_weights, pack_activations, unpack_results, reference
from accelerator import Device, PING, STATUS, CONFIG, WEIGHTS, ACTIVATIONS, START, READ, RESET


class SerialLink:
    """Fragment every response and retain the real bytes written by Device."""
    def __init__(self, respond):
        self.respond = respond
        self.incoming = bytearray()
        self.writes = []
        self.events = []

    @property
    def in_waiting(self):
        return min(1, len(self.incoming))

    def write(self, data):
        self.writes.append(data)
        self.events.append('write')
        self.incoming.extend(self.respond(data))
        return len(data)

    def read(self, size):
        result = bytes(self.incoming[:size])
        del self.incoming[:size]
        return result

    def flush(self):
        self.events.append('flush')

    def reset_input_buffer(self):
        self.events.append('drain')
        self.incoming.clear()

    def close(self):
        self.events.append('close')


def device_for(link):
    with patch.dict(sys.modules, {'serial': SimpleNamespace(Serial=lambda *a, **kw: link)}):
        return Device('FAKE')


class HostTests(unittest.TestCase):
    def test_crc_standard_and_corruption(self):
        self.assertEqual(binascii.crc_hqx(b'123456789',0xffff),0x29b1)
        for size in (0,1,9,250,256):
            packet=frame(17,255,bytes(range(256))[:size])
            self.assertEqual(decode(packet),(17,255,bytes(range(256))[:size]))
            for bit in range(8):
                corrupt=bytearray(packet); corrupt[7]^=1<<bit
                with self.assertRaises(ValueError): decode(bytes(corrupt))

    def test_bounds_and_precision(self):
        for c in (Config(0,8,1),Config(9,8,1),Config(512,512,1),Config(8,8,1025),
                  Config(8,8,1,32),Config(8,8,1,0,128),Config(8,8,1,relu=2)):
            with self.assertRaises(ValueError): c.pack()
        for c in (Config(512,16,16),Config(16,512,16),Config(8,8,1024)):
            self.assertEqual(len(c.pack()),9)
        with self.assertRaises(ValueError): pack_activations([[256]*8],Config(8,8,1))
        with self.assertRaises(ValueError): pack_activations([[1.1]*8],Config(8,8,1))

    def test_independent_dot_product_and_layout(self):
        rng=random.Random(12)
        cfg=Config(24,40,5,4,-3)
        a=[[rng.randint(-12,12) for _ in range(cfg.k)] for _ in range(cfg.m)]
        w=[[rng.randint(-12,12) for _ in range(cfg.n)] for _ in range(cfg.k)]
        self.assertEqual(len(pack_weights(w,cfg)),cfg.k*cfg.n)
        self.assertEqual(len(pack_activations(a,cfg)),cfg.m*cfg.k)
        result=reference(a,w,cfg)
        raw=bytes(result[m][n+c]&255 for n in range(0,cfg.n,8) for m in range(cfg.m) for c in range(8))
        self.assertEqual(unpack_results(raw,cfg),result)
        with self.assertRaises(ValueError): unpack_results(raw[:-1],cfg)

    def test_fragmented_response_noise_and_sequence_wrap(self):
        def respond(packet):
            cmd, seq, payload = decode(packet)
            self.assertEqual((cmd, payload), (PING, b''))
            return b'noise\x55' + frame(cmd | 128, seq, b'\0AI8')
        link = SerialLink(respond)
        dev = device_for(link)
        dev.sequence = 255
        self.assertEqual(dev.command(PING), b'AI8')
        self.assertEqual(dev.command(PING), b'AI8')
        self.assertEqual([decode(p)[1] for p in link.writes], [255, 0])
        dev.close()
        self.assertEqual(link.events[-1], 'close')

    def test_invalid_responses_do_not_retry_start(self):
        good = frame(START | 128, 0, b'\0')
        responses = [
            (good[:-1] + bytes([good[-1] ^ 1]), ValueError),
            (frame(START | 128, 1, b'\0'), RuntimeError),
            (frame(PING | 128, 0, b'\0'), RuntimeError),
            (frame(START | 128, 0, b''), RuntimeError),
            (frame(START | 128, 0, b'\4'), RuntimeError),
            (b'\x55\xaa\x01\x93\x00\x01\x01', RuntimeError),
        ]
        for response, error in responses:
            with self.subTest(response=response):
                link = SerialLink(lambda packet: response)
                with self.assertRaises(error):
                    device_for(link).command(START)
                self.assertEqual(len(link.writes), 1)

    def test_partial_response_times_out_without_retry(self):
        link = SerialLink(lambda packet: frame(START | 128, 0, b'\0')[:5])
        dev = device_for(link)
        with patch('accelerator.time.monotonic', side_effect=[0, 0, 0, 4]):
            with self.assertRaises(TimeoutError): dev.command(START)
        self.assertEqual(len(link.writes), 1)

    def test_partial_write_is_reported(self):
        link = SerialLink(lambda packet: b'')
        with patch.object(link, 'write', return_value=2) as write:
            with self.assertRaisesRegex(TimeoutError, 'Incomplete request'):
                device_for(link).command(START)
        self.assertEqual(write.call_count, 1)

    def test_explicit_recovery_drains_stale_reply_before_reset(self):
        def respond(packet):
            cmd, seq, payload = decode(packet)
            self.assertEqual((cmd, payload), (RESET, b''))
            return frame(cmd | 128, seq, b'\0')
        link = SerialLink(respond)
        link.incoming.extend(frame(START | 128, 255, b'\0'))
        with patch('accelerator.time.sleep', side_effect=lambda delay: link.events.append(delay)):
            device_for(link).recover()
        self.assertEqual(link.events, ['flush', 0.150, 'drain', 'write'])

    def test_infer_chunking_status_and_output_order(self):
        # Independent scripted device: Y = [A, -A], with no use of host packing
        # or reference functions to construct its replies or expected transcript.
        cfg = Config(8, 16, 40)
        act = [[(m + c) % 31 - 15 for c in range(8)] for m in range(40)]
        wgt = [[int(k == n) - int(k == n - 8) for n in range(16)] for k in range(8)]
        weights = bytes(int(k == c) for k in range(8) for c in range(8))
        weights += bytes((-int(k == c)) & 255 for k in range(8) for c in range(8))
        activations = bytes(v & 255 for row in act for v in row)
        result_bytes = activations + bytes((-v) & 255 for row in act for v in row)
        transcript = []
        loaded = {WEIGHTS: bytearray(), ACTIVATIONS: bytearray()}
        started = False
        polls = 0

        def respond(packet):
            nonlocal started, polls
            cmd, seq, payload = decode(packet)
            transcript.append(cmd)
            data = b''
            if cmd == CONFIG:
                self.assertEqual(payload, struct.pack('<HHHBbB', 8, 16, 40, 0, 0, 0))
            elif cmd in loaded:
                self.assertEqual(int.from_bytes(payload[:2], 'little'), len(loaded[cmd]) // 8)
                self.assertLessEqual(len(payload), 250)
                loaded[cmd].extend(payload[2:])
            elif cmd == START:
                self.assertEqual(bytes(loaded[WEIGHTS]), weights)
                self.assertEqual(bytes(loaded[ACTIVATIONS]), activations)
                started = True
            elif cmd == STATUS:
                if started: polls += 1
                done = polls > 1
                data = struct.pack('<BBBB6HII', 30 if done else 29 if started else 28,
                                   0, 0, 0, 16, 40, 80 if done else 0, 16, 40, 80, 1234, 0)
            elif cmd == READ:
                offset, count = struct.unpack('<HB', payload)
                self.assertGreater(polls, 1)
                self.assertGreater(count, 0)
                self.assertLessEqual(count, 31)
                data = result_bytes[offset*8:(offset+count)*8]
            else:
                self.fail(f'unexpected command {cmd}')
            return frame(cmd | 128, seq, b'\0' + data)

        with patch('accelerator.time.sleep'):
            actual = device_for(SerialLink(respond)).infer(act, wgt, cfg)
        self.assertEqual(actual, [row + [-v for v in row] for row in act])
        self.assertEqual(transcript, [CONFIG, WEIGHTS, ACTIVATIONS, ACTIVATIONS,
                                     STATUS, START, STATUS, STATUS, READ, READ, READ])

    def test_infer_rejects_incomplete_load_and_device_error(self):
        act = [[1]*8]
        wgt = [[0]*8 for _ in range(8)]
        for ready, error in [(False, 0), (True, 0x21)]:
            with self.subTest(ready=ready, error=error):
                calls = []
                def command(cmd, payload=b''):
                    calls.append(cmd)
                    if cmd == STATUS:
                        return struct.pack('<BBBB6HII', 28 if ready else 4, 0,
                                           error if START in calls else 0, 0,
                                           8, 1, 0, 8, 1, 1, 0, 0)
                    return b''
                dev = device_for(SerialLink(lambda packet: b''))
                with patch.object(dev, 'command', side_effect=command):
                    with self.assertRaises(RuntimeError): dev.infer(act, wgt, Config(8,8,1))
                self.assertEqual(START in calls, ready)
                self.assertNotIn(READ, calls)


if __name__=='__main__': unittest.main()
