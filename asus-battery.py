#!/usr/bin/env python3
# Battery of an ASUS ROG wireless mouse, read straight from its receiver over
# hidraw. The kernel has no driver that hands these to UPower, so the widget
# asks the mouse itself: the same 0x12 0x07 query Armoury Crate sends.
#
# Prints one JSON object: {"model", "percent", "millivolts", "charging"}, or
# {} when no ASUS receiver answers (unplugged, mouse asleep, no permission).
# Access needs a udev rule tagging the receiver's hidraw node with uaccess.
import json
import os
import select

ASUS_VENDOR = "00000B05"
QUERY = bytes([0x12, 0x07])


def uevent(node):
    out = {}
    try:
        with open(f"/sys/class/hidraw/{node}/device/uevent") as f:
            for line in f:
                key, _, value = line.strip().partition("=")
                out[key] = value
    except OSError:
        pass
    return out


def vendor_interface(node):
    # The command channel is the interface whose report descriptor opens on
    # the vendor usage page 0xFF01; the others are the pointer and media keys.
    try:
        with open(f"/sys/class/hidraw/{node}/device/report_descriptor", "rb") as f:
            return f.read(3) == b"\x06\x01\xff"
    except OSError:
        return False


def query(path):
    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    try:
        while select.select([fd], [], [], 0)[0]:
            os.read(fd, 64)
        os.write(fd, QUERY + bytes(64 - len(QUERY)))
        for _ in range(10):
            if not select.select([fd], [], [], 0.5)[0]:
                return None
            reply = os.read(fd, 64)
            # A sleeping or unpaired mouse answers 0xFF 0xAA instead of an echo.
            if reply[:2] == QUERY:
                return reply
        return None
    finally:
        os.close(fd)


def main():
    for node in sorted(os.listdir("/sys/class/hidraw")):
        info = uevent(node)
        if not info.get("HID_ID", "").upper().startswith("0003:" + ASUS_VENDOR):
            continue
        if not vendor_interface(node):
            continue
        try:
            reply = query("/dev/" + node)
        except OSError:
            continue
        if not reply or len(reply) < 10 or not 0 < reply[4] <= 100:
            continue
        print(json.dumps({
            "model": info.get("HID_NAME", "").strip(),
            "percent": reply[4],
            "millivolts": reply[8] << 8 | reply[7],
            "charging": reply[9] != 0,
        }))
        return
    print("{}")


main()
