#!/usr/bin/env python3
"""Liest das gerade angezeigte Bild vom DRM-Scanout und schreibt es als PNG.

Fuer den Pi mit drm-kms-egl: es gibt dort keinen Compositor, der ein
Bildschirmfoto machen koennte. Braucht root (DRM-Handles nur mit
CAP_SYS_ADMIN) und einen linearen Framebuffer (vc4 mit Modifier 0).
Die Eigenschaft `rotation` der Ebene wird angewendet: ivi-homescreen
rendert mit GL von unten nach oben und laesst die Ebene spiegeln
(REFLECT_Y), das PNG zeigt also, was man auf dem Panel sieht.
Aufruf: sudo python3 drm_shot.py ausgabe.png [/dev/dri/cardN]
"""
import ctypes, ctypes.util, glob, mmap, os, struct, sys, zlib

drm = ctypes.CDLL(ctypes.util.find_library('drm') or 'libdrm.so.2')

class PlaneRes(ctypes.Structure):
    _fields_ = [('count_planes', ctypes.c_uint32), ('planes', ctypes.POINTER(ctypes.c_uint32))]

class Plane(ctypes.Structure):
    _fields_ = [('count_formats', ctypes.c_uint32), ('formats', ctypes.POINTER(ctypes.c_uint32)),
                ('plane_id', ctypes.c_uint32), ('crtc_id', ctypes.c_uint32), ('fb_id', ctypes.c_uint32),
                ('crtc_x', ctypes.c_uint32), ('crtc_y', ctypes.c_uint32), ('x', ctypes.c_uint32),
                ('y', ctypes.c_uint32), ('possible_crtcs', ctypes.c_uint32), ('gamma_size', ctypes.c_uint32)]

class FB2(ctypes.Structure):
    _fields_ = [('fb_id', ctypes.c_uint32), ('width', ctypes.c_uint32), ('height', ctypes.c_uint32),
                ('pixel_format', ctypes.c_uint32), ('modifier', ctypes.c_uint64), ('flags', ctypes.c_uint32),
                ('handles', ctypes.c_uint32 * 4), ('pitches', ctypes.c_uint32 * 4),
                ('offsets', ctypes.c_uint32 * 4)]

class ObjProps(ctypes.Structure):
    _fields_ = [('count_props', ctypes.c_uint32), ('props', ctypes.POINTER(ctypes.c_uint32)),
                ('prop_values', ctypes.POINTER(ctypes.c_uint64))]

class Prop(ctypes.Structure):
    _fields_ = [('prop_id', ctypes.c_uint32), ('flags', ctypes.c_uint32), ('name', ctypes.c_char * 32)]

drm.drmModeObjectGetProperties.restype = ctypes.POINTER(ObjProps)
drm.drmModeGetProperty.restype = ctypes.POINTER(Prop)
drm.drmModeGetPlaneResources.restype = ctypes.POINTER(PlaneRes)
drm.drmModeGetPlane.restype = ctypes.POINTER(Plane)
drm.drmModeGetFB2.restype = ctypes.POINTER(FB2)

XR24, AR24 = 0x34325258, 0x34325241
PLANE = 0xeeeeeeee
ROTATE_180, REFLECT_X, REFLECT_Y = 0x4, 0x10, 0x20


def rotation(fd, plane_id):
    props = drm.drmModeObjectGetProperties(fd, plane_id, PLANE)
    if not props:
        return 1
    for i in range(props.contents.count_props):
        prop = drm.drmModeGetProperty(fd, props.contents.props[i])
        if prop and prop.contents.name == b'rotation':
            return props.contents.prop_values[i]
    return 1


def scanout(card):
    fd = os.open(card, os.O_RDWR | os.O_CLOEXEC)
    drm.drmSetClientCap(fd, 2, 1)  # DRM_CLIENT_CAP_UNIVERSAL_PLANES
    res = drm.drmModeGetPlaneResources(fd)
    if not res:
        os.close(fd)
        return None
    for i in range(res.contents.count_planes):
        p = drm.drmModeGetPlane(fd, res.contents.planes[i])
        if p and p.contents.fb_id and p.contents.crtc_id:
            fb = drm.drmModeGetFB2(fd, p.contents.fb_id)
            if fb and fb.contents.pixel_format in (XR24, AR24):
                return fd, fb.contents, rotation(fd, p.contents.plane_id)
    os.close(fd)
    return None


def main():
    out = sys.argv[1]
    cards = sys.argv[2:] or sorted(glob.glob('/dev/dri/card*'))
    found = next((s for s in map(scanout, cards) if s), None)
    if not found:
        sys.exit('kein aktiver Framebuffer (XR24/AR24) gefunden')
    fd, fb, rot = found
    if rot & ROTATE_180:
        rot ^= REFLECT_X | REFLECT_Y
    flip_x, flip_y = bool(rot & REFLECT_X), bool(rot & REFLECT_Y)
    if rot & ~(0x1 | REFLECT_X | REFLECT_Y | ROTATE_180):
        sys.exit(f'Drehung {rot:#x} wird nicht unterstuetzt')
    if fb.modifier != 0:
        sys.exit(f'Framebuffer nicht linear (Modifier {fb.modifier:#x})')
    if not fb.handles[0]:
        sys.exit('kein Handle - als root starten')
    prime = ctypes.c_int()
    if drm.drmPrimeHandleToFD(fd, fb.handles[0], os.O_CLOEXEC | os.O_RDWR, ctypes.byref(prime)):
        sys.exit('drmPrimeHandleToFD fehlgeschlagen')
    w, h, pitch = fb.width, fb.height, fb.pitches[0]
    size = fb.offsets[0] + pitch * h
    with mmap.mmap(prime.value, size, mmap.MAP_SHARED, mmap.PROT_READ) as m:
        raw = m[fb.offsets[0]:size]
    rows = bytearray()
    for y in (range(h - 1, -1, -1) if flip_y else range(h)):
        line = raw[y * pitch:y * pitch + w * 4]  # B G R A je Pixel
        if flip_x:
            px = [line[i:i + 4] for i in range(0, len(line), 4)]
            line = b''.join(reversed(px))
        rgb = bytearray(w * 3)
        rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]
        rows += b'\0' + rgb

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))
    with open(out, 'wb') as f:
        f.write(png)
    print(f'{out}: {w}x{h}, rotation {rot:#x}')


main()
