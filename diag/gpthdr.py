# SPDX-License-Identifier: GPL-2.0-or-later
import struct,sys,zlib
for name in ("bak","now"):
    d=open(f"/root/l4diff/{name}.bin","rb").read()
    for base in (0, 40960*512):
        mbr=d[base:base+512]; h=d[base+512:base+1024]
        sig=struct.unpack_from("<I",mbr,440)[0]
        f=struct.unpack_from("<8sIIIIQQQQ16sQIII",h,0)
        hs=f[2]; crc_calc=zlib.crc32(h[:16]+b"\0"*4+h[20:hs])&0xffffffff
        print(f"{name} @sector {base//512}: mbr_sig=0x{sig:08x} gpt sig={f[0]} hdrsize={hs} crc=0x{f[3]:08x} (calc 0x{crc_calc:08x}) reserved={f[4]} my={f[5]} alt={f[6]} first={f[7]} last={f[8]} entries_lba={f[10]} n={f[11]} esz={f[12]} ecrc=0x{f[13]:08x} mbr_ptype=0x{mbr[450]:02x} p_start={struct.unpack_from('<I',mbr,454)[0]} p_size={struct.unpack_from('<I',mbr,458)[0]}")
