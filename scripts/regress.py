"""Run the checked-in core regression using Vivado XSim, preserving logs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = ['pkg_accelerator', 'mac_unit', 'systolic_array', 'sram_controller',
       'axi_stream_input', 'axi_stream_output', 'quantize_unit',
       'layer_ctrl_fsm', 'inference_accelerator_top']


def run_tool(bin_dir, tool, args, cwd, log):
    exe = bin_dir / (tool + ('.bat' if os.name == 'nt' else ''))
    result = subprocess.run([str(exe), *map(str, args)], cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors='replace')
    (cwd / log).write_text(result.stdout, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'{tool} exited {result.returncode}: {cwd / log}\n{result.stdout[-4000:]}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vivado-bin', type=Path, default=Path(os.environ.get(
        'VIVADO_BIN', 'C:/AMDDesignTools/2025.2/Vivado/bin')))
    parser.add_argument('--output', type=Path, default=ROOT / 'build/regression')
    parser.add_argument('--vectors', type=Path, default=ROOT / 'verification/tests')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    files = [ROOT / 'rtl' / (name + '.sv') for name in RTL]
    run_tool(args.vivado_bin, 'xvlog', ['--sv', *files,
             ROOT / 'tb/tb_inference_accelerator.sv'], out, 'compile.log')
    run_tool(args.vivado_bin, 'xelab', ['tb_inference_accelerator', '-s', 'core_sim'],
             out, 'elaborate.log')
    results = []
    for directory in sorted(args.vectors.resolve().glob('test_*')):
        (out / 'xsim_args.txt').write_text('core_sim\n-runall\n-testplusarg\n"test_dir=' +
                                         directory.as_posix() + '"\n')
        output = run_tool(args.vivado_bin, 'xsim', ['-f', 'xsim_args.txt'],
                   out, directory.name + '.log')
        match = re.search(r'RESULT: PASS \((\d+)/(\d+) outputs matched\)', output)
        passed = bool(match and match[1] == match[2] and
                      'TEST FAILED' not in output and 'FSM ERROR' not in output)
        item = dict(test=directory.name, passed=passed,
                    matched=int(match[1]) if match else 0)
        results.append(item)
        print(item, flush=True)
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    return 0 if results and all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
