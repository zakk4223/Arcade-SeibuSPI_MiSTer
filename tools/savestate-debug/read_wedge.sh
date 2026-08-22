#!/usr/bin/env bash
# Screenshot the wedged board and decode the overlay bits.
SSH() { sshpass -p 1 ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 root@192.168.1.125 "$@" 2>&1 \
        | grep -v "post-quantum\|store now\|upgraded\. See\|^\*\*"; }
SSH 'echo "screenshot wedge_bits.png" > /dev/MiSTer_cmd; sleep 3; ls -la /media/fat/screenshots/wedge_bits.png'
cd "$CLAUDE_JOB_DIR/tmp" || exit 2
sshpass -p 1 scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
    root@192.168.1.125:/media/fat/screenshots/wedge_bits.png shots/ 2>&1 | grep -v "post-quantum\|store now\|upgraded\|^\*\*"
python3 - <<'PY'
import zlib, struct
f = open('shots/wedge_bits.png','rb').read()
# minimal PNG decode: IHDR + concatenated IDAT, 8-bit RGB, no interlace
pos, w, h, idat = 8, 0, 0, b''
while pos < len(f):
    ln = struct.unpack('>I', f[pos:pos+4])[0]; typ = f[pos+4:pos+8]
    data = f[pos+8:pos+8+ln]
    if typ == b'IHDR': w, h, bd, ct = *struct.unpack('>II', data[:8]), data[8], data[9]
    elif typ == b'IDAT': idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
stride = w*3
rows = []
prev = bytearray(stride)
p = 0
for y in range(h):
    ft = raw[p]; p += 1
    line = bytearray(raw[p:p+stride]); p += stride
    if ft == 1:
        for i in range(3, stride): line[i] = (line[i] + line[i-3]) & 255
    elif ft == 2:
        for i in range(stride): line[i] = (line[i] + prev[i]) & 255
    elif ft == 3:
        for i in range(stride):
            a = line[i-3] if i >= 3 else 0
            line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
    elif ft == 4:
        for i in range(stride):
            a = line[i-3] if i >= 3 else 0
            b = prev[i]; c = prev[i-3] if i >= 3 else 0
            pa, pb, pc = abs(b-c), abs(a-c), abs(a+b-2*c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 255
    rows.append(bytes(line)); prev = line

def px(x, y):
    r = rows[y]; return r[x*3], r[x*3+1], r[x*3+2]

y = 24                      # middle of the 16..31 band
mark = px(4, y)
print("size %dx%d  marker px(4,24) = %s" % (w, h, mark))
if not (mark[0] > 200 and mark[1] < 80):
    print("NO RED MARKER -> the core is not wedged (or the band is elsewhere)")
else:
    names = ["st0","st1","st2","st3","is_load","pause",
             "io_stall","z80dl_stall","ds_stall","snapshot","in_stub"]
    bits = []
    for i in range(11):
        x = 16 + i*16 + 8
        r,g,b = px(x, y)
        bits.append(1 if (r > 128 and g > 128) else 0)
    st = bits[0] | bits[1]<<1 | bits[2]<<2 | bits[3]<<3
    for n, v in zip(names, bits): print("  %-12s %d" % (n, v))
    ST = {0:"S_IDLE",1:"S_ASK",2:"S_STREAM",3:"S_STREAMING",4:"S_INVAL",
          5:"S_RELEASE",6:"S_DONE",8:"S_ARM",9:"S_SETTLE",10:"S_WAITVBL"}
    print("  => spi_ss state = %d (%s)" % (st, ST.get(st,"?")))
PY
