#!/usr/bin/env python3
"""Niri + grim capture. Never changes focus or the clipboard.

Only captures the visible WoW window. Fullscreen and fully visible tiled windows
are supported; unavailable/occluded geometry fails closed instead of capturing
some other app. Pixel capture and vision use the same bounds.
"""
from pixel_codec import decode_compact
import argparse
import io
import json
import subprocess
import time
from PIL import Image


def ipc(kind):
    return json.loads(subprocess.check_output(['niri', 'msg', '--json', kind], timeout=3))


def window_bounds(process_name='WowB'):
    windows, workspaces, outputs = ipc('windows'), ipc('workspaces'), ipc('outputs')
    matches = [w for w in windows if w['app_id'].lower().removesuffix('.exe') == process_name.lower().removesuffix('.exe')]
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one WoW window; found %d' % len(matches))
    w = matches[0]
    ws = next(s for s in workspaces if s['id'] == w['workspace_id'])
    if not ws['is_active'] or ws.get('active_window_id') != w['id']:
        raise RuntimeError('WoW must be the active window on its visible workspace')
    output = outputs[ws['output']]['logical']
    if output['scale'] != 1 or output['transform'] != 'Normal':
        raise RuntimeError('This capture backend currently requires output scale 1 and Normal transform')
    layout = w['layout']
    width, height = layout['window_size']
    if [width, height] == [output['width'], output['height']]:
        x, y = output['x'], output['y']
    else:
        pos = layout.get('tile_pos_in_workspace_view')
        if pos is None:
            raise RuntimeError('Window bounds unavailable; use borderless fullscreen')
        offset = layout['window_offset_in_tile']
        x, y = int(output['x'] + pos[0] + offset[0]), int(output['y'] + pos[1] + offset[1])
        if x < output['x'] or y < output['y'] or x + width > output['x'] + output['width'] or y + height > output['y'] + output['height']:
            raise RuntimeError('WoW is partly offscreen; use borderless fullscreen')
    if any(other.get('is_floating') and other['workspace_id'] == ws['id'] for other in windows if other['id'] != w['id']):
        raise RuntimeError('A floating window may obscure WoW; capture paused')
    return x, y, width, height


def capture(process_name='WowB', strip=False, cell=4, cells=200, rows=48, anchor="top"):
    x, y, width, height = window_bounds(process_name)
    if strip:
        capture_height = min(height, rows * cell + 8)
        if anchor == "bottom": y += height - capture_height
        width, height = min(width, cells * cell + 8), capture_height
    data = subprocess.check_output(['grim', '-g', f'{x},{y} {width}x{height}', '-'], timeout=5)
    return Image.open(io.BytesIO(data)).convert('RGB')


def decode(image, cell=4, cells=200, rows=48, anchor="top"):
    px = image.load()
    for oy in range(9):
        for ox in range(9):
            if ox + cells * cell > image.width or oy + rows * cell > image.height:
                continue
            if cells==512 and rows==1:
                result=decode_compact(lambda x,y:px[x,y],ox,oy,cells,cell)
                if result: return result
                continue
            out, acc, bits, needed = bytearray(), 0, 0, 6
            for i in range(cells * rows):
                r, g, b = px[ox + (i % cells) * cell + cell // 2, oy + (i // cells) * cell + cell // 2]
                acc = (acc << 3) | ((4 if r >= 128 else 0) + (2 if g >= 128 else 0) + (1 if b >= 128 else 0))
                bits += 3
                while bits >= 8:
                    bits -= 8
                    out.append((acc >> bits) & 255)
                    acc &= (1 << bits) - 1
                if len(out) >= 2 and out[:2] != b'\xc7\x1a':
                    break
                if len(out) >= 6:
                    needed = 8 + int.from_bytes(out[4:6], 'big')
                    if needed > cells * rows * 3 // 8:
                        break
                if len(out) >= needed and needed >= 8:
                    s1 = s2 = 0
                    for v in out[2:needed - 2]:
                        s1 = (s1 + v) % 255
                        s2 = (s2 + s1) % 255
                    if out[needed - 2:needed] == bytes([s1, s2]):
                        return {'id': int.from_bytes(out[2:4], 'big'), 'text': out[6:needed - 2].decode('utf-8')}
                    break
    return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--process-name', default='WowB')
    p.add_argument('--anchor', choices=['top','bottom'], default='top')
    p.add_argument('--cell', type=int, default=4)
    p.add_argument('--cells', type=int, default=200)
    p.add_argument('--max-rows', type=int, default=48)
    p.add_argument('--interval-ms', type=int, default=750)
    p.add_argument('--screenshot')
    p.add_argument('--test-image')
    args = p.parse_args()
    if args.screenshot:
        capture(args.process_name).save(args.screenshot)
        return
    if args.test_image:
        print(json.dumps(decode(Image.open(args.test_image).convert('RGB'), args.cell, args.cells, args.max_rows)))
        return
    last, warning, warned_at = None, '', 0
    while True:
        delay = max(args.interval_ms, 100)
        try:
            image = capture(args.process_name, True, args.cell, args.cells, args.max_rows, args.anchor)
            msg = decode(image, args.cell, args.cells, args.max_rows)
            token = (msg['id'], msg['text']) if msg else None
            if token and token != last:
                print(json.dumps(msg, ensure_ascii=False), flush=True)
            last = token
        except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as exc:
            if str(exc) != warning or time.monotonic() - warned_at > 60:
                print(json.dumps({'warn': str(exc)}), flush=True)
                warning, warned_at = str(exc), time.monotonic()
            last = None
            delay = max(delay, 1000)
        time.sleep(delay / 1000)


if __name__ == '__main__':
    main()
