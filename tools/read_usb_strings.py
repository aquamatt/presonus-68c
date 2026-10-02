#!/usr/bin/env python3
# ABOUTME: Prints every USB string descriptor of a device by index, including the
# ABOUTME: per-channel names a USB audio interface supplies via iChannelNames.
"""Print every USB string descriptor of a device, by index.

Read-only: issues standard GET_DESCRIPTOR(STRING) control requests through
usbfs, the same request lsusb makes. Needs root (or write access to the
/dev/bus/usb node). Standard library only.

On the Studio 68c, indices 14-19 name the six playback channels and 20-25
the six capture channels (iChannelNames in the USB descriptors).

Usage: sudo python3 read_usb_strings.py [VID:PID] [MAX_INDEX]
Default device is the PreSonus Studio 68c, 194f:010b.
"""
import ctypes
import fcntl
import os
import sys


class CtrlTransfer(ctypes.Structure):
    # struct usbdevfs_ctrltransfer from <linux/usbdevice_fs.h>
    _fields_ = [
        ("bRequestType", ctypes.c_uint8),
        ("bRequest", ctypes.c_uint8),
        ("wValue", ctypes.c_uint16),
        ("wIndex", ctypes.c_uint16),
        ("wLength", ctypes.c_uint16),
        ("timeout", ctypes.c_uint32),
        ("data", ctypes.c_void_p),
    ]


# _IOWR('U', 0, struct usbdevfs_ctrltransfer)
USBDEVFS_CONTROL = (3 << 30) | (ctypes.sizeof(CtrlTransfer) << 16) | (ord("U") << 8)
USB_DIR_IN = 0x80
USB_REQ_GET_DESCRIPTOR = 0x06
USB_DT_STRING = 0x03


def find_node(vid, pid):
    base = "/sys/bus/usb/devices"
    for name in sorted(os.listdir(base)):
        path = os.path.join(base, name)
        try:
            with open(os.path.join(path, "idVendor")) as f:
                v = f.read().strip()
            with open(os.path.join(path, "idProduct")) as f:
                p = f.read().strip()
        except OSError:
            continue
        if v == vid and p == pid:
            with open(os.path.join(path, "busnum")) as f:
                bus = int(f.read())
            with open(os.path.join(path, "devnum")) as f:
                dev = int(f.read())
            return f"/dev/bus/usb/{bus:03d}/{dev:03d}"
    return None


def get_string_raw(fd, index, langid):
    buf = ctypes.create_string_buffer(255)
    xfer = CtrlTransfer(
        USB_DIR_IN, USB_REQ_GET_DESCRIPTOR, (USB_DT_STRING << 8) | index,
        langid, 255, 1000, ctypes.cast(buf, ctypes.c_void_p))
    n = fcntl.ioctl(fd, USBDEVFS_CONTROL, xfer)
    raw = buf.raw[:n]
    if n < 2 or raw[1] != USB_DT_STRING:
        return None
    return raw[2:raw[0]]


def main():
    vidpid = sys.argv[1] if len(sys.argv) > 1 else "194f:010b"
    max_index = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    vid, pid = vidpid.lower().split(":")
    node = find_node(vid, pid)
    if node is None:
        sys.exit(f"device {vidpid} not found")
    try:
        fd = os.open(node, os.O_RDWR)
    except PermissionError:
        sys.exit(f"permission denied on {node}: run with sudo")
    try:
        langs = get_string_raw(fd, 0, 0)
        langid = int.from_bytes(langs[:2], "little") if langs else 0x0409
        print(f"device {vidpid} at {node}, langid 0x{langid:04x}")
        for i in range(1, max_index + 1):
            try:
                raw = get_string_raw(fd, i, langid)
            except OSError:
                continue  # device stalls on indices it does not define
            if raw is not None:
                print(f"{i:3d}  {raw.decode('utf-16-le', errors='replace')}")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
