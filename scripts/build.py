"""Build in a fresh directory and record exact source/artifact hashes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def hashes(paths):
    return {str(p.relative_to(ROOT)).replace('\\', '/'):
            hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vivado-bin', type=Path, default=Path(os.environ.get(
        'VIVADO_BIN', 'C:/AMDDesignTools/2025.2/Vivado/bin')))
    parser.add_argument('--output', type=Path, default=ROOT/'build/vivado_final')
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('output directory must be empty; choose a new path to preserve previous evidence')
    out.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT/'rtl').glob('*.sv')) + [ROOT/'constraints/nexys4ddr.xdc',
               ROOT/'scripts/build_vivado.tcl', Path(__file__).resolve()]
    manifest = dict(started_utc=datetime.now(timezone.utc).isoformat(),
                    sources=hashes(sources), passed=False)
    manifest_path = out/'manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
    exe = args.vivado_bin/('vivado.bat' if os.name == 'nt' else 'vivado')
    command = [str(exe), '-mode', 'batch', '-source', str(ROOT/'scripts/build_vivado.tcl'),
               '-log', str(out/'vivado.log'), '-journal', str(out/'vivado.jou'),
               '-tclargs', str(out)]
    manifest['command'] = command
    with (out/'console.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    manifest.update(finished_utc=datetime.now(timezone.utc).isoformat(),
                    returncode=result.returncode, sources_unchanged=hashes(sources)==manifest['sources'])
    result_path, bit_path = out/'result.txt', out/'nexys4ddr_top.bit'
    manifest['passed'] = (result.returncode == 0 and manifest['sources_unchanged'] and
                          result_path.exists() and bit_path.exists() and
                          'BITSTREAM_GENERATED=1' in result_path.read_text())
    manifest['artifacts'] = hashes(sorted(out.glob('*.rpt'))+sorted(out.glob('*.bit'))+
                                   sorted(out.glob('*.dcp')))
    manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
    if not manifest['passed']:
        raise SystemExit(f'Build failed: inspect {out / "console.log"}')
    print(result_path.read_text(), end='')
    print(f'Build PASS; source and artifact hashes: {manifest_path}')


if __name__ == '__main__':
    main()
