#!/usr/bin/env python3
"""Replay the VPN client's static-routing request against an off-link gateway.

Run inside a fresh network namespace (`unshare -n`). Uses raw netlink, so it
needs no iproute2. Loopback stands in for the WAN interface: the kernel's
nexthop check (fib_check_nh) is the same code for every device.

Asserts the facts setup/00-vm-setup.sh relies on:
  1. with the gateway reachable only via an onlink default route, the client's
     "<peer>/32 via <gw>" (no onlink) is refused with ENETUNREACH -- the -101
     seen in gnosis_vpn_root's "static routing setup error";
  2. so is the kit's table-200 SSH bypass route;
  3. a link-scope host route for the gateway makes both succeed.
"""
import errno, socket, struct, sys

s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0); s.bind((0, 0))
REQ, ACK, EXCL, CREATE, REPLACE = 1, 4, 0x200, 0x400, 0x100
seq = 0

def attr(t, d): return struct.pack('<HH', 4 + len(d), t) + d + b'\0' * (-len(d) % 4)

def send(typ, flags, body):
    global seq; seq += 1
    s.send(struct.pack('<IHHII', 16 + len(body), typ, flags | REQ | ACK, seq, 0) + body)
    d = s.recv(65536)
    assert struct.unpack_from('<H', d, 4)[0] == 2, "expected NLMSG_ERROR/ACK"
    return -struct.unpack_from('<i', d, 16)[0]

ip = socket.inet_aton
LO = socket.if_nametoindex('lo')
send(16, 0, struct.pack('<BxHiII', 0, 0, LO, 1, 1))                         # lo up
send(20, CREATE | EXCL, struct.pack('<BBBBI', 2, 32, 0, 0, LO)               # 13.140.130.179/32
     + attr(1, ip('13.140.130.179')) + attr(2, ip('13.140.130.179')))

def route(dst, plen, gw=None, table=254, scope=0, onlink=False, flags=CREATE | EXCL):
    rt = struct.pack('<BBBBBBBBI', 2, plen, 0, 0, table, 4, scope, 1, 4 if onlink else 0)
    a = (attr(1, ip(dst)) if plen else b'') + attr(4, struct.pack('<I', LO)) + (attr(5, ip(gw)) if gw else b'')
    return send(24, flags, rt + a)

GW, fails = '13.140.128.1', 0
def expect(label, rc, want):
    global fails
    ok = rc == want
    fails += not ok
    got = 'OK' if rc == 0 else errno.errorcode.get(rc, rc)
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}: {got}")

assert route('0.0.0.0', 0, GW, onlink=True) == 0, "could not build the onlink default route"
expect("client route, gateway off-link  -> ENETUNREACH", route('31.220.99.4', 32, GW), errno.ENETUNREACH)
expect("SSH bypass,   gateway off-link  -> ENETUNREACH", route('0.0.0.0', 0, GW, table=200, flags=CREATE | REPLACE), errno.ENETUNREACH)
assert route(GW, 32, scope=253, flags=CREATE | REPLACE) == 0, "could not add the gateway link route"
expect("client route, gateway link route -> accepted", route('31.220.99.4', 32, GW), 0)
expect("SSH bypass,   gateway link route -> accepted", route('0.0.0.0', 0, GW, table=200, flags=CREATE | REPLACE), 0)
sys.exit(1 if fails else 0)
