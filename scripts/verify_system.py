"""Run byte-level full-system regression and pin-level UART smoke regression."""
import argparse
from pathlib import Path
import re
from regress import ROOT, RTL, run_tool
from system_vectors import generate

ALL_RTL = RTL + ['uart_rx','uart_tx','uart_packet','accelerator_uart_service','nexys4ddr_top']


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--vivado-bin',type=Path,default=Path('C:/AMDDesignTools/2025.2/Vivado/bin'))
    parser.add_argument('--serial-only',action='store_true')
    args=parser.parse_args()
    for serial in ([True] if args.serial_only else [False,True]):
        out=ROOT/'build'/('serial_system' if serial else 'byte_system')
        out.mkdir(parents=True,exist_ok=True)
        total=generate(out/'vectors.txt',serial)
        run_tool(args.vivado_bin,'xvlog',['--sv',*[ROOT/'rtl'/f'{x}.sv' for x in ALL_RTL],
                 ROOT/'tb/tb_uart_system.sv'],out,'compile.log')
        (out/'elab_args.txt').write_text('tb_uart_system\n-generic_top\n"SERIAL='+
                                       str(int(serial))+'"\n-s\nsystem_sim\n')
        run_tool(args.vivado_bin,'xelab',['-f','elab_args.txt'],out,'elaborate.log')
        (out/'args.txt').write_text('system_sim\n-runall\n-testplusarg\n"vectors='+
                                   (out/'vectors.txt').as_posix()+'"\n')
        output=run_tool(args.vivado_bin,'xsim',['-f','args.txt'],out,'simulation.log')
        match=re.search(r'SYSTEM PASS: (\d+) transactions',output)
        if not match or int(match[1]) != total or 'Fatal:' in output:
            raise RuntimeError(output[-5000:])
        print(f'PASS: {total} transactions, serial={serial}',flush=True)


if __name__ == '__main__':
    main()
