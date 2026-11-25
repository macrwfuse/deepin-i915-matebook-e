#!/usr/bin/env python3
"""Compare a freshly built i915.ko against the i915.ko Deepin 25.3.0 shipped.

Checks
  1. vermagic is byte-identical to the reference (and to the running kernel)
  2. modinfo "depends=" list is identical (kvmgt and friends resolve against it)
  3. "retpoline" matches (the loader taints the kernel when it does not)
  4. every exported symbol (__ksymtab* + __kcrctab*) has the same CRC
  5. every undefined symbol's modversion CRC matches Deepin's Module.symvers
     (both the classic __versions table and the 6.13+ __version_ext_* tables
     are understood)

The reference can be
  * the real Deepin module (i915.ko or i915.ko.zst), or
  * a JSON ABI fingerprint emitted by emit-abi-fixture.py from that module.
Use the JSON form when the original binary is not available, e.g. on a CI
runner that only has the upstream tarball plus Deepin's headers package.

"intree" is reported but not treated as an error: an external (M=) build
cannot emit it, so the kernel would add TAINT_OOT_MODULE. It is metadata,
not ABI, and the module is unsigned anyway (TAINT_UNSIGNED_MODULE).

usage: verify-module.py <new.ko> <reference.ko[.zst]|abi.json> <Module.symvers>
                        <expected-vermagic>
exit: 0 all good, 1 mismatch, 2 usage/format error
"""

import json
import struct
import subprocess
import sys


def read_elf(path):
    """Return raw ELF bytes, transparently decompressing zstd."""
    raw = open(path, 'rb').read()
    if raw[:4] != b'\x7fELF':
        raw = subprocess.run(['zstd', '-d', '-c', path],
                             capture_output=True, check=True).stdout
        if raw[:4] != b'\x7fELF':
            sys.exit('not an ELF file: %s' % path)
    return raw


class Elf:
    """Minimal 64-bit little-endian relocatable ELF reader."""

    def __init__(self, raw):
        self.raw = raw
        if raw[:5] != b'\x7fELF\x02' or raw[5] != 1:
            sys.exit('expected ELF64 little-endian')
        e_shoff = struct.unpack_from('<Q', raw, 0x28)[0]
        e_shentsize = struct.unpack_from('<H', raw, 0x3a)[0]
        e_shnum = struct.unpack_from('<H', raw, 0x3c)[0]
        e_shstrndx = struct.unpack_from('<H', raw, 0x3e)[0]
        self.sh = [struct.unpack_from('<IIQQQQIIQQ', raw,
                                      e_shoff + i * e_shentsize)
                   for i in range(e_shnum)]
        base = self.sh[e_shstrndx][4]
        self.names = []
        for s in self.sh:
            end = raw.index(b'\0', base + s[0])
            self.names.append(raw[base + s[0]:end].decode())
        self.by_name = {self.names[i]: i for i in range(len(self.sh))}

    def data(self, name):
        s = self.sh[self.by_name[name]]
        return self.raw[s[4]:s[4] + s[5]]

    def has(self, name):
        return name in self.by_name

    def symbols(self):
        st = self.sh[self.by_name['.symtab']]
        strtab = self.sh[self.by_name['.strtab']][4]
        out = []
        for k in range(st[5] // st[9]):
            off, info, other, shndx = struct.unpack_from(
                '<IBBH', self.raw, st[4] + k * st[9])
            end = self.raw.index(b'\0', strtab + off)
            out.append((self.raw[strtab + off:end].decode(), shndx))
        return out

    def c_string(self, off):
        end = self.raw.index(b'\0', off)
        return self.raw[off:end].decode()


def undefined_crcs(elf, name_len):
    """symbol -> crc for every undefined symbol recorded in __versions*."""
    ver = {}

    # classic table: struct modversion_info { u64 crc; char name[N]; }
    if elf.has('__versions'):
        blob = elf.data('__versions')
        entry = 8 + name_len
        if len(blob) % entry:
            sys.exit('__versions size %d is not a multiple of %d'
                     % (len(blob), entry))
        for k in range(len(blob) // entry):
            crc = struct.unpack_from('<Q', blob, k * entry)[0]
            name = blob[k * entry + 8:].split(b'\0')[0].decode()
            ver[name] = crc

    # 6.13+ extended table: parallel u32 crc[] and char names[]
    if elf.has('__version_ext_crcs'):
        if not elf.has('__version_ext_names'):
            sys.exit('__version_ext_crcs without __version_ext_names')
        crcs = elf.data('__version_ext_crcs')
        names = elf.data('__version_ext_names')
        count = len(crcs) // 4
        if len(crcs) % 4:
            sys.exit('__version_ext_crcs is not u32 aligned')
        pos = 0
        for k in range(count):
            end = names.index(b'\0', pos)
            ver.setdefault(names[pos:end].decode(),
                           struct.unpack_from('<I', crcs, 4 * k)[0])
            pos = end + 1

    return ver


def exported_crcs(elf):
    """symbol -> crc for every EXPORT_SYMBOL*'d symbol.

    kernel_symbol is three s32 offsets; the name offset is relative to the
    address of the name field itself, so relocations are the reliable way to
    recover the names. Entry size comes from the section size / count.
    """
    out = {}

    for tab, crctab in (('__ksymtab', '__kcrctab'),
                        ('__ksymtab_gpl', '__kcrctab_gpl')):
        if not elf.has(tab) or not elf.has(crctab):
            continue
        rel = '.rela' + tab
        if not elf.has(rel):
            sys.exit('%s has no relocation section' % tab)

        sh = elf.sh[elf.by_name[tab]]
        rela = elf.sh[elf.by_name[rel]]
        crcs = elf.data(crctab)
        syms = elf.symbols()

        # kernel_symbol is 3 * s32 in 6.18 (value, name, namespace)
        entry_size = 12
        if sh[5] % entry_size:
            sys.exit('%s size %d is not a multiple of %d'
                     % (tab, sh[5], entry_size))

        names = {}
        for k in range(rela[5] // rela[9]):
            off, info, addend = struct.unpack_from(
                '<QQq', elf.raw, rela[4] + k * rela[9])
            sym = info >> 32
            field = off % entry_size
            if field != 4:          # only the name field matters here
                continue
            names[off // entry_size] = syms[sym][0].replace('__kstrtab_', '')

        for idx, name in names.items():
            crc = struct.unpack_from('<I', crcs, 4 * idx)[0]
            out[name] = crc

    return out


def modinfo(elf, key):
    blob = elf.data('.modinfo')
    prefix = key.encode() + b'='
    vals = [item[len(prefix):].decode()
            for item in blob.split(b'\0')
            if item.startswith(prefix)]
    return vals


def load_reference(path):
    """Return the reference facts either from a module or from a JSON fixture."""
    if path.endswith('.json'):
        doc = json.load(open(path, encoding='utf-8'))
        try:
            return {
                'kind': 'fixture',
                'vermagic': doc['vermagic'],
                'depends': doc['depends'],
                'retpoline': doc['retpoline'],
                'intree': doc['intree'],
                'exported': {k: int(v, 16) for k, v in doc['exported'].items()},
                'sha256': doc.get('reference_sha256', ''),
                'package': doc.get('package', ''),
            }
        except KeyError as e:
            sys.exit('ABI fixture %s lacks key %s' % (path, e))

    elf = Elf(read_elf(path))
    return {
        'kind': 'module',
        'vermagic': modinfo(elf, 'vermagic'),
        'depends': modinfo(elf, 'depends'),
        'retpoline': modinfo(elf, 'retpoline'),
        'intree': modinfo(elf, 'intree'),
        'exported': exported_crcs(elf),
        'sha256': '',
        'package': '',
    }


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    new_path, ref_path, symvers_path, expected_vermagic = sys.argv[1:5]

    new = Elf(read_elf(new_path))
    ref = load_reference(ref_path)

    errors = []

    # ---- vermagic ---------------------------------------------------------
    got = modinfo(new, 'vermagic')
    new_vm = got[0] if got else '<none>'
    ref_vm = ref['vermagic'][0] if ref['vermagic'] else '<none>'
    if new_vm != expected_vermagic:
        errors.append('vermagic %r != expected %r' % (new_vm, expected_vermagic))
    if new_vm != ref_vm:
        errors.append('vermagic %r != reference %r' % (new_vm, ref_vm))

    # ---- depends ----------------------------------------------------------
    new_dep = modinfo(new, 'depends')
    if new_dep != ref['depends']:
        errors.append('depends=%r != reference %r' % (new_dep, ref['depends']))

    # ---- retpoline --------------------------------------------------------
    new_rp = modinfo(new, 'retpoline')
    if new_rp != ref['retpoline']:
        errors.append('retpoline=%r != reference %r' % (new_rp, ref['retpoline']))

    # ---- intree (informational) ------------------------------------------
    new_intree = modinfo(new, 'intree')

    # ---- exported symbols ------------------------------------------------
    new_exp = exported_crcs(new)
    ref_exp = ref['exported']
    if set(new_exp) != set(ref_exp):
        errors.append('exported symbol set differs: missing %s, extra %s'
                      % (sorted(set(ref_exp) - set(new_exp)),
                         sorted(set(new_exp) - set(ref_exp))))
    exp_bad = [(n, '%08x' % new_exp[n], '%08x' % ref_exp[n])
               for n in sorted(set(new_exp) & set(ref_exp))
               if new_exp[n] != ref_exp[n]]

    # ---- undefined symbol CRCs vs Module.symvers --------------------------
    theirs = {}
    for line in open(symvers_path, errors='replace'):
        f = line.split()
        if len(f) >= 2:
            theirs[f[1]] = int(f[0], 16)

    # x86_64: MODULE_NAME_LEN = 64 - sizeof(unsigned long) = 56
    name_len = 56
    new_ver = undefined_crcs(new, name_len)

    undef = {name for name, shndx in new.symbols() if shndx == 0 and name}
    undef.add('module_layout')     # checked separately by the kernel loader

    missing = sorted(n for n in undef if n not in theirs)
    unversioned = sorted(n for n in undef if n in theirs and n not in new_ver)
    crc_bad = [(n, '%08x' % new_ver[n], '%08x' % theirs[n])
               for n in sorted(undef)
               if n in theirs and n in new_ver and new_ver[n] != theirs[n]]

    print('reference         : %s%s'
          % (ref_path,
             ' (%s, sha256 %s…)' % (ref['package'], ref['sha256'][:16])
             if ref['kind'] == 'fixture' else ''))
    print('vermagic          : %s' % new_vm)
    print('depends           : %s' % (new_dep[0] if new_dep else '<none>'))
    print('retpoline         : %s' % (new_rp[0] if new_rp else '<none>'))
    print('intree            : %s (reference %s)'
          % (new_intree[0] if new_intree else '<none>',
             ref['intree'][0] if ref['intree'] else '<none>'))
    print('exported symbols  : %d (crc mismatches: %d)' % (len(new_exp), len(exp_bad)))
    print('undefined symbols : %d (unversioned: %d, crc mismatches: %d, '
          'not in Module.symvers: %d)'
          % (len(undef), len(unversioned), len(crc_bad), len(missing)))

    for n, ours, ref_crc in exp_bad[:20]:
        print('  EXPORT CRC MISMATCH %-40s ours=%s deepin=%s' % (n, ours, ref_crc))
    for n, ours, want in crc_bad[:20]:
        print('  CRC MISMATCH %-40s ours=%s deepin=%s' % (n, ours, want))
    for n in unversioned[:10]:
        print('  no version crc recorded: %s' % n)
    for n in missing[:10]:
        print('  not exported by Deepin: %s' % n)

    if new_intree != ref['intree']:
        print()
        print('NOTE: intree=%s while Deepin ships intree=%s; the loader will add'
              % (new_intree[0] if new_intree else '<none>',
                 ref['intree'][0] if ref['intree'] else '<none>'))
        print('      TAINT_OOT_MODULE (it is added for unsigned modules anyway).')
        print('      Everything below the kernel ABI level still matches.')

    if exp_bad:
        errors.append('%d exported symbol CRCs differ' % len(exp_bad))
    if crc_bad:
        errors.append('%d undefined symbol CRCs differ' % len(crc_bad))
    if unversioned:
        errors.append('%d symbols have no version CRC' % len(unversioned))
    if missing:
        errors.append('%d symbols are not exported by Deepin' % len(missing))

    if errors:
        print()
        for e in errors:
            print('ERROR: %s' % e)
        return 1
    print()
    print('OK: module is ABI-compatible with the running kernel')
    return 0


if __name__ == '__main__':
    sys.exit(main())
