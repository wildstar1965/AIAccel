"""Targeted RTL unit test runner."""
import argparse
import os
from pathlib import Path
from regress import ROOT, RTL, run_tool


def main():
    tests = [('tb_uart_phy',['uart_rx','uart_tx'],'UART PHY PASS'),
             ('tb_core_contract',RTL,'CORE CONTRACT PASS'),
             ('tb_uart_faults',RTL+['uart_packet','accelerator_uart_service'],'UART FAULTS PASS')]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vivado-bin', type=Path, default=Path(os.environ.get(
        'VIVADO_BIN', 'C:/AMDDesignTools/2025.2/Vivado/bin')))
    parser.add_argument('--top', choices=[entry[0] for entry in tests],
                        help='run only this testbench (default: all)')
    args = parser.parse_args()
    bin_dir = args.vivado_bin
    for top,files,marker in tests:
        if args.top and args.top != top:
            continue
        out=ROOT/'build'/top
        out.mkdir(parents=True,exist_ok=True)
        run_tool(bin_dir,'xvlog',['--sv',*[ROOT/'rtl'/f'{name}.sv' for name in files],
                 ROOT/'tb'/f'{top}.sv'],out,'compile.log')
        run_tool(bin_dir,'xelab',[top,'-s','unit_sim'],out,'elaborate.log')
        output=run_tool(bin_dir,'xsim',['unit_sim','-runall'],out,'simulation.log')
        if marker not in output or 'Fatal:' in output:
            raise RuntimeError(output[-5000:])
        print(marker,flush=True)


if __name__=='__main__':
    main()
