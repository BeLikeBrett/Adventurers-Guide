"""Calibrated compact one-row decoder shared by all Python capture backends."""
def decode_compact(px, ox=0, oy=0, cells=512, cell=1):
    try:
        palette = [px(ox+i*cell+cell//2, oy+cell//2) for i in range(16)]
        for channel in range(3):
            values = [p[channel] for p in palette]
            if values[-1]-values[0] < 100 or any(values[i] >= values[i+1] for i in range(15)):
                return None
        # Map captured channel values through the captured ramp; no assumption
        # about the WoW gamma slider or compositor's per-channel color curve.
        maps = [[min(range(16), key=lambda i: abs(value-palette[i][channel])) for value in range(256)] for channel in range(3)]
        out,acc,bits,needed=bytearray(),0,0,6
        for i in range(16,cells):
            rgb=px(ox+i*cell+cell//2,oy+cell//2)
            v=maps[0][rgb[0]]*256+maps[1][rgb[1]]*16+maps[2][rgb[2]]
            acc=(acc<<12)|v;bits+=12
            while bits>=8:
                bits-=8;out.append((acc>>bits)&255);acc&=(1<<bits)-1
                if len(out)==2 and out[:2]!=b'\xc7\x1a':return None
                if len(out)==6:
                    needed=8+int.from_bytes(out[4:6],'big')
                    if needed>720+8:return None
                if len(out)>=needed:break
            if len(out)>=needed and needed>=8:
                s1=s2=0
                for byte in out[2:needed-2]:s1=(s1+byte)%255;s2=(s2+s1)%255
                if out[needed-2:needed]!=bytes([s1,s2]):return None
                return {'id':int.from_bytes(out[2:4],'big'),'text':out[6:needed-2].decode('utf-8')}
    except (IndexError,ValueError,UnicodeDecodeError):
        return None
    return None
