#!/usr/bin/env python3
"""Emit the ABI fixture for verify-module.py from the module Deepin shipped.

usage: emit-abi-fixture.py <reference i915.ko> <out.json>
"""
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_verifier():
    spec = importlib.util.spec_from_file_location(
        'verify_module', HERE / 'verify-module.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ref, out = sys.argv[1], sys.argv[2]
    vm = load_verifier()
    raw = Path(ref).read_bytes()
    elf = vm.Elf(raw)

    undef = sorted({n for n, shndx in elf.symbols() if shndx == 0 and n}
                   | {'module_layout'})
    doc = {
        '_comment': (
            'ABI fingerprint of the i915.ko shipped by Deepin in '
            'linux-image-6.18.56-amd64-desktop-rolling_25.01.01.40_amd64.deb. '
            'verify-module.py --abi reads this in place of the reference ELF, '
            'so a rebuild can be checked on a machine that does not have the '
            'original module.'),
        'kernel_release': '6.18.56-amd64-desktop-rolling',
        'package': 'linux-image-6.18.56-amd64-desktop-rolling 25.01.01.40',
        'reference_sha256': hashlib.sha256(raw).hexdigest(),
        'reference_size': len(raw),
        'vermagic': vm.modinfo(elf, 'vermagic'),
        'depends': vm.modinfo(elf, 'depends'),
        'retpoline': vm.modinfo(elf, 'retpoline'),
        'intree': vm.modinfo(elf, 'intree'),
        'exported': {k: '%08x' % v
                     for k, v in sorted(vm.exported_crcs(elf).items())},
        'undefined': undef,
    }
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
        f.write('\n')
    print('wrote %s (%d bytes): %d exported, %d undefined symbols'
          % (out, os.path.getsize(out), len(doc['exported']), len(undef)))


if __name__ == '__main__':
    main()
