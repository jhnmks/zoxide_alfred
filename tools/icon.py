"""Draw the workflow icon as a supersampled PNG without external dependencies."""
import struct
import zlib


def make_icon(destination):
    size = 512
    scale = 2
    polygons = [
        ([(64, 164), (64, 134), (80, 116), (208, 116), (242, 152), (430, 152), (448, 170), (448, 380), (430, 398), (82, 398), (64, 380)], (25, 127, 135)),
        ([(64, 184), (448, 184), (448, 380), (430, 398), (82, 398), (64, 380)], (58, 211, 188)),
        ([(182, 224), (342, 224), (342, 252), (232, 330), (342, 330), (342, 362), (176, 362), (176, 332), (286, 256), (182, 256)], (17, 37, 53)),
    ]

    def inside(x, y, points):
        result = False
        previous = points[-1]
        for current in points:
            ax, ay = previous
            bx, by = current
            if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
                result = not result
            previous = current
        return result

    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            totals = [0, 0, 0, 0]
            for dy in range(scale):
                for dx in range(scale):
                    px, py = x + (dx + .5) / scale, y + (dy + .5) / scale
                    # Rounded midnight tile with a subtle vertical gradient.
                    cx, cy = min(max(px, 100), 412), min(max(py, 100), 412)
                    color = (0, 0, 0, 0)
                    if (px - cx) ** 2 + (py - cy) ** 2 < 76 ** 2:
                        color = (int(28 - py / 80), int(47 - py / 80), int(67 - py / 64), 255)
                    for points, fill in polygons:
                        if inside(px, py, points):
                            color = (*fill, 255)
                    for channel in range(4):
                        totals[channel] += color[channel]
            rows.extend(round(value / (scale * scale)) for value in totals)

    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))

    destination.write_bytes(b'\x89PNG\r\n\x1a\n' +
                            chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 6, 0, 0, 0)) +
                            chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))
