"""Build byte-level UART transactions and independent numerical scoreboards."""
from pathlib import Path
import binascii
import random
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'host'))
from accelerator import (Config, frame, reference, pack_weights, pack_activations,
                         PING, STATUS, CONFIG, WEIGHTS, ACTIVATIONS, START, READ, RESET)


def generate(path, serial=False):
    sequence = 0
    transactions = []

    def request(cmd, data=b'', expect=b'\0', *, packet=None, gap=0):
        nonlocal sequence
        req = frame(cmd, sequence, data) if packet is None else packet(sequence)
        transactions.append((req, gap, cmd | 128, sequence, list(expect)))
        sequence = (sequence+1) & 255

    request(PING, expect=b'\0AI8\1\0\4\10\10')
    request(START, expect=b'\7')
    request(READ, struct.pack('<HB', 0, 1), expect=b'\7')
    request(0x77, expect=b'\10')
    request(PING, b'bad', expect=b'\2')
    request(PING, expect=b'\1', packet=lambda s: frame(PING, s)[:-1]+bytes([frame(PING,s)[-1]^1]))
    def bad_version(s):
        body=bytes([2,PING,s,0,0])
        return b'\x55\xaa'+body+struct.pack('<H',binascii.crc_hqx(body,0xffff))
    request(PING,expect=b'\3',packet=bad_version)
    if not serial:
        # Incomplete packet times out; cmd/sequence were already received.
        request(PING, expect=b'\11', packet=lambda s: frame(PING,s)[:6])
        request(PING, expect=b'\2', packet=lambda s: b'\x55\xaa\x01'+bytes([PING,s])+b'\x01\x01')
    # Invalid dimensions, alignment, weight capacity, shift, ReLU, activation capacity.
    for cfg in [(0,8,1,0,0,0),(9,8,1,0,0,0),(512,512,1,0,0,0),
                (8,8,1,32,0,0),(8,8,1,0,0,2),(8,8,1025,0,0,0)]:
        request(CONFIG, struct.pack('<HHHBbB', *cfg), expect=b'\5')
    rng = random.Random(2048)
    cases = []
    if serial:
        cfg = Config(8,8,1)
        cases.append(('serial_identity', cfg, [[1,-2,3,-4,5,-6,7,-8]],
                      [[int(i==j) for j in range(8)] for i in range(8)]))
    else:
        for directory in sorted((ROOT/'verification/tests').glob('test_*')):
            k,n,m,shift,zp,relu = map(int, (directory/'config.txt').read_text().split())
            cfg = Config(k,n,m,shift,zp,bool(relu))
            # Decode actual stored vectors, independently of original golden model.
            def words(name):
                return [int(x,16).to_bytes(8,'little') for x in (directory/name).read_text().split()]
            wbytes = b''.join(words('weights.hex'))
            wgt = [[0]*n for _ in range(k)]
            p = 0
            for oc in range(0,n,8):
                for ic in range(k):
                    wgt[ic][oc:oc+8] = struct.unpack('8b',wbytes[p:p+8]); p += 8
            abytes = b''.join(words('activations.hex'))[:m*k]
            act = [list(struct.unpack(f'{k}b',abytes[i*k:(i+1)*k])) for i in range(m)]
            expected = reference(act,wgt,cfg)
            flat = [expected[s][oc+c] for oc in range(0,n,8) for s in range(m) for c in range(8)]
            assert flat == list(map(int,(directory/'expected.txt').read_text().split())), directory
            cases.append((directory.name,cfg,act,wgt))
        for k,n,m,shift,zp,relu in [(512,16,16,14,-13,False),(16,512,16,7,127,True),
                                  (8,8,1024,31,-128,False),(24,40,5,5,7,False)]:
            cfg = Config(k,n,m,shift,zp,relu)
            act = [[rng.randint(-128,127) for _ in range(k)] for _ in range(m)]
            wgt = [[rng.randint(-128,127) for _ in range(n)] for _ in range(k)]
            cases.append((f'boundary_{k}_{n}_{m}',cfg,act,wgt))
    for name,cfg,act,wgt in cases:
        request(CONFIG, cfg.pack())
        request(START, expect=b'\7')
        # Bad-CRC load must not modify counts; following offset-zero write must succeed.
        bad_load = struct.pack('<H',0)+pack_weights(wgt,cfg)[:8]
        request(WEIGHTS,bad_load,expect=b'\1',packet=lambda s,d=bad_load: frame(WEIGHTS,s,d)[:-2]+b'\0\0')
        request(WEIGHTS,struct.pack('<H',1)+b'\0'*8,expect=b'\6')
        for cmd,raw in [(WEIGHTS,pack_weights(wgt,cfg)), (ACTIVATIONS,pack_activations(act,cfg))]:
            for offset in range(0,len(raw),248):
                request(cmd,struct.pack('<H',offset//8)+raw[offset:offset+248])
        request(WEIGHTS,bad_load,expect=b'\6')  # duplicate offset is rejected
        request(STATUS,expect=[0,28,0,0,0,*struct.pack('<6HII',cfg.k*cfg.n//8,cfg.m*cfg.k//8,0,
                    cfg.k*cfg.n//8,cfg.m*cfg.k//8,cfg.m*cfg.n//8,0,0)])
        # Previous run cycle count and cumulative rejected counter vary.
        transactions[-1][4][17:25] = [-1]*8
        expected = reference(act,wgt,cfg)
        raw_output = bytes(expected[m][n+c]&255 for n in range(0,cfg.n,8)
                           for m in range(cfg.m) for c in range(8))
        for repeat in range(2 if 'identity' in name else 1):
            request(START)
            # Byte test attempts a write while a long inference remains active.
            if not serial and cfg.m*cfg.k*cfg.n//64 > 1000:
                request(CONFIG,cfg.pack(),expect=b'\4')
                request(START,expect=b'\4')
                request(ACTIVATIONS,struct.pack('<H',0)+b'\0'*8,expect=b'\4')
                request(READ,struct.pack('<HB',0,1),expect=b'\4')
                request(STATUS,expect=[0,29,0,0]+[-1]*21)
            wait_cycles = cfg.m*(cfg.k//8)*(cfg.n//8)*40+1000
            request(STATUS, gap=wait_cycles,
                    expect=[0,30,0,0,0,*struct.pack('<6HII',cfg.k*cfg.n//8,cfg.m*cfg.k//8,
                       cfg.m*cfg.n//8,cfg.k*cfg.n//8,cfg.m*cfg.k//8,cfg.m*cfg.n//8,0,0)])
            transactions[-1][4][17:25] = [-1]*8
            for offset in range(0,len(raw_output)//8,31):
                count = min(31,len(raw_output)//8-offset)
                request(READ,struct.pack('<HB',offset,count),expect=b'\0'+raw_output[offset*8:(offset+count)*8])
            request(READ,struct.pack('<HB',len(raw_output)//8,1),expect=b'\6')
        if not serial and cfg.m*cfg.k*cfg.n//64 > 1000:
            request(START)
            request(RESET)  # explicit abort during a long active inference
            request(START,expect=b'\7')
        print(f'{name}: {cfg.m*cfg.n} reference outputs', flush=True)
    request(RESET)
    request(START,expect=b'\7')
    with path.open('w') as f:
        for req,gap,cmd,seq,expected in transactions:
            f.write(f'{len(req)} {gap} {cmd} {seq} {len(expected)}\n')
            f.write(' '.join(f'{b:02x}' for b in req)+'\n')
            f.write(' '.join(str(b) for b in expected)+'\n')
    return len(transactions)


if __name__ == '__main__':
    target=ROOT/'build/system_vectors.txt'
    target.parent.mkdir(exist_ok=True)
    print(generate(target),'transactions')
