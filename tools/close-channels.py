#!/usr/bin/env python3
"""
close-channels.py -- retarget this node's outgoing channels, for the pin-cfg arm.

    ./tools/close-channels.py --list                    # what is open now
    ./tools/close-channels.py --keep 0xRELAY            # plan only
    ./tools/close-channels.py --keep 0xRELAY --send     # initiate closures
    ./tools/close-channels.py --finalize --send         # after the grace period

WHAT THIS DOES, AND WHY IT CAN

The node's Safe holds the channel stakes, and the node key is authorised on the
Safe's management module. hopr-lib's own integration test states the arrangement:
a chain operation "goes out as an `execTransactionFromModule` and the Safe holds
the value being moved. The node key only signs, and pays the gas."

So everything needed is on this machine: the chain key in the identity keystore,
and the Safe and module addresses in gnosisvpn-hopr.safe. No new identity, no
faucet code, no funds lost -- closing returns the stake to the Safe.

BLOKLI IS THE ONLY CHAIN ENDPOINT

There is no RPC URL to configure. blokli-inspector answers everything:

    query node-overview <node>   outgoing channels, already separated from
                                 incoming and with destinations resolved to
                                 addresses
    query chain-info             deployed channels contract, closure grace
                                 period, chain id, gas price
    query tx-count <node>        the signer's nonce
    tx --payload <hex>           broadcast the signed transaction

Locally this needs only eth-account, to sign. Not web3: with blokli doing the
reads and the broadcast, an RPC client would be a second source of truth about
the same chain, and the failure that invites -- a plan built against one endpoint
and signed against another -- is the kind nobody notices afterwards.

WHAT IT REFUSES TO ASSUME

The HoprChannels ABI below is written from the HOPR contracts and was NOT
verified against deployed bytecode. Two things make it safe to sign with:

  1. the encoder self-tests at startup against vectors computed independently of
     it, and the module selector must equal Safe's published 0x468721a7;
  2. the first close of a run is sent ALONE as a canary, and the chain is then
     re-read to require that channel to have actually moved to PendingToClose
     before any others are sent.

A wrong ABI therefore costs one transaction's gas on one channel, and stops. It
cannot quietly do nothing -- or something else -- to a whole channel set.

No address is guessed either: the channels contract comes from chain-info.

TWO PHASES, ON PURPOSE

Closing is `initiateOutgoingChannelClosure` then, after the grace period,
`finalizeOutgoingChannelClosure`. This does not sit and wait between them: an
unattended loop around a wait is worse than being told when to come back.
`--list` prints when each channel becomes finalizable.

NON-INTERACTIVE. `--send` is the deliberate act, so this drives from a test
harness. Replacing a human reading the plan: --max-close caps a run, --keep must
name an actually-open channel, and every transaction is recorded in an
append-only audit log before it is sent and again on its answer.

Requires: python3, eth-account (`pip install eth-account`), blokli-inspector
(https://github.com/hoprnet/blokli-client).
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    from eth_account import Account
    from eth_utils import keccak, to_checksum_address
except ImportError:
    sys.exit(
        "eth-account is required:  pip install eth-account\n"
        "It is the only local dependency -- signing uses the audited library "
        "rather than an implementation written alongside this script."
    )

# Safe's module-execution selector: a published constant, so it independently
# checks that the encoder below produces the right bytes.
EXEC_FROM_MODULE_SELECTOR = bytes.fromhex("468721a7")
OPERATION_CALL = 0


# ---------------------------------------------------------------- encoding --

def selector(signature):
    return keccak(text=signature)[:4]


def enc_address(a):
    return bytes(12) + bytes.fromhex(a[2:] if a.startswith("0x") else a)


def enc_uint(n):
    return int(n).to_bytes(32, "big")


def enc_bytes_tail(b):
    return enc_uint(len(b)) + b + bytes((-len(b)) % 32)


def encode_channel_call(fn_sig, destination):
    """initiate/finalizeOutgoingChannelClosure(address)."""
    return selector(fn_sig) + enc_address(destination)


def encode_exec_from_module(to, value, data, operation):
    """
    execTransactionFromModule(address,uint256,bytes,uint8).

    Four static head words -- the dynamic `bytes` contributes an offset, not its
    content -- then the length-prefixed, right-padded payload.
    """
    head = enc_address(to) + enc_uint(value) + enc_uint(4 * 32) + enc_uint(operation)
    return selector("execTransactionFromModule(address,uint256,bytes,uint8)") \
        + head + enc_bytes_tail(data)


# Vectors computed independently of this implementation. If the encoder drifts,
# or eth_utils' keccak is not Ethereum's, this fails at startup rather than on
# chain. The outer selector doubles as a check against a published constant.
_T_DEST = "0x" + "b2" * 20
_T_CHAN = "0x" + "ff" * 20
_T_INNER = "7c8e28da" + "00" * 12 + "b2" * 20
_T_OUTER_PREFIX = "468721a7" + "00" * 12 + "ff" * 20


def self_test():
    inner = encode_channel_call("initiateOutgoingChannelClosure(address)", _T_DEST)
    if inner.hex() != _T_INNER:
        sys.exit(f"encoder self-test failed (inner): {inner.hex()} != {_T_INNER}")
    outer = encode_exec_from_module(_T_CHAN, 0, inner, OPERATION_CALL)
    if not outer.startswith(EXEC_FROM_MODULE_SELECTOR):
        sys.exit(f"module selector {outer[:4].hex()} != 468721a7; refusing to sign")
    if not outer.hex().startswith(_T_OUTER_PREFIX) or len(outer) != 228:
        sys.exit(f"encoder self-test failed (outer): len={len(outer)} {outer.hex()[:80]}")


# ------------------------------------------------------------------ blokli --

class Blokli:
    def __init__(self, binary, url, timeout=60):
        self.binary, self.url, self.timeout = binary, url, timeout

    def run(self, *args):
        cmd = [self.binary, "--url", self.url, "--format", "json", *args]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout)
        except FileNotFoundError:
            sys.exit(f"{self.binary} not found. Build it from "
                     f"https://github.com/hoprnet/blokli-client, or pass --blokli-bin.")
        except subprocess.TimeoutExpired:
            sys.exit(f"{self.binary} timed out against {self.url}")
        if r.returncode != 0:
            sys.exit(f"{' '.join(cmd[:6])} …\nfailed ({r.returncode}): "
                     f"{r.stderr.strip()[:400]}")
        out = r.stdout.strip()
        if not out:
            return None
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return out        # tx submission may answer with a bare hash


def unwrap(doc, *names):
    """Reach through blokli's response wrapper without assuming its shape."""
    if isinstance(doc, dict):
        for n in names:
            if n in doc:
                return doc[n]
        if len(doc) == 1:
            return next(iter(doc.values()))
    return doc


def first_number(doc):
    """Pull a scalar count out of whatever tx-count wraps it in."""
    if isinstance(doc, bool):
        return None
    if isinstance(doc, (int, float)):
        return int(doc)
    if isinstance(doc, str) and doc.strip().lstrip("-").isdigit():
        return int(doc.strip())
    if isinstance(doc, dict):
        for v in doc.values():
            got = first_number(v)
            if got is not None:
                return got
    return None


# ----------------------------------------------------------------- helpers --

def read_safe_file(path):
    safe = module = None
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line.startswith("safe_address:"):
            safe = line.split(":", 1)[1].strip().strip("\"'")
        elif line.startswith("module_address:"):
            module = line.split(":", 1)[1].strip().strip("\"'")
    if not safe or not module:
        sys.exit(f"could not read safe/module addresses from {path}")
    return safe, module


def load_account(keystore, passfile):
    """
    Decrypt the node's chain key. Held in memory only; never written anywhere.

    If the identity file is not a standard eth keystore v3 this fails LOUDLY
    rather than guessing at a derivation -- a wrongly derived key yields a
    valid-looking address that owns nothing, and transactions that revert for
    reasons nobody can trace.
    """
    try:
        blob = json.loads(keystore.read_text())
    except Exception as e:
        sys.exit(f"{keystore} is not JSON ({e}); not an eth keystore v3 file.")
    try:
        return Account.from_key(Account.decrypt(blob, passfile.read_text().strip()))
    except Exception as e:
        sys.exit(f"could not decrypt {keystore}: {e}\n"
                 "If it is HOPR's own container rather than eth keystore v3, extract "
                 "the chain key with HOPR's tooling and pass GVPN_CHAIN_KEY instead.")


def fmt_hopr(wei):
    try:
        return f"{int(str(wei).split()[0]) / 1e18:.6f} wxHOPR"
    except (TypeError, ValueError, IndexError):
        return str(wei)


def parse_iso(s):
    if not s:
        return 0
    try:
        return int(time.mktime(time.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S")))
    except ValueError:
        return 0


def is_pending(status):
    return str(status).lower().replace("_", "").startswith("pending")


def is_open(status):
    return str(status).lower() == "open"


# -------------------------------------------------------------------- main --

def main():
    ap = argparse.ArgumentParser(description="Retarget this node's outgoing channels.")
    ap.add_argument("--blokli-url", default=os.environ.get(
        "BLOKLI_URL", "https://blokli.jura.hoprnet.link"))
    ap.add_argument("--blokli-bin", default=os.environ.get(
        "GVPN_BLOKLI_BIN", "blokli-inspector"))
    ap.add_argument("--identity-dir", default="/var/lib/gnosisvpn/.config")
    ap.add_argument("--node", default=os.environ.get("GVPN_NODE_ADDRESS"),
                    help="node chain address; defaults to the keystore's own")
    ap.add_argument("--channels", default=os.environ.get("GVPN_CHANNELS_CONTRACT"),
                    help="override the channels contract from chain-info")
    ap.add_argument("--keep", action="append", default=[], metavar="0xADDR")
    ap.add_argument("--finalize", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--send", action="store_true",
                    help="sign and broadcast. Non-interactive: this flag IS the "
                         "confirmation, so it drives from a test harness.")
    ap.add_argument("--max-close", type=int, default=8, metavar="N",
                    help="refuse to act on more than N channels in one run")
    ap.add_argument("--audit-log", default=os.environ.get(
        "GVPN_CHANNEL_AUDIT", "/var/log/gnosisvpn/channel-close.log"))
    ap.add_argument("--confirmations", type=int, default=2)
    ap.add_argument("--gas-limit", type=int, default=400000,
                    help="per transaction; blokli offers no estimator")
    ap.add_argument("--gas-price-gwei", type=float, default=None)
    ap.add_argument("--canary-settle", type=int, default=5,
                    help="seconds before re-reading the chain to verify the canary")
    ap.add_argument("--no-canary", action="store_true",
                    help="skip the verified first close. Only once the ABI has "
                         "been proven against this deployment.")
    args = ap.parse_args()

    self_test()

    idir = Path(args.identity_dir)
    safe_addr, module_addr = read_safe_file(idir / "gnosisvpn-hopr.safe")
    bl = Blokli(args.blokli_bin, args.blokli_url)

    # The signing identity is needed even for --list, because node-overview is
    # keyed by the node address.
    keyhex = os.environ.get("GVPN_CHAIN_KEY")
    acct = (Account.from_key(keyhex) if keyhex
            else load_account(idir / "gnosisvpn-hopr.id", idir / "gnosisvpn-hopr.pass"))
    node_addr = to_checksum_address(args.node) if args.node else acct.address

    info = unwrap(bl.run("query", "chain-info"), "chain_info", "chainInfo") or {}
    channels_addr = args.channels or info.get("channel_dst") or info.get("channelDst")
    if not channels_addr:
        sys.exit("blokli chain-info reported no channels contract (channel_dst); "
                 "pass --channels, or point --blokli-url at the right network.")
    grace = int(info.get("channel_closure_grace_period")
                or info.get("channelClosureGracePeriod") or 0)
    chain_id = int(info.get("chain_id") or info.get("chainId") or 0)

    print(f"blokli       {args.blokli_url}")
    print(f"chain id     {chain_id}")
    print(f"node         {node_addr}")
    print(f"safe         {safe_addr}")
    print(f"module       {module_addr}")
    print(f"channels     {channels_addr}"
          f"{'' if args.channels else '   (from chain-info)'}")
    print(f"grace period {grace}s")

    def outgoing():
        ov = unwrap(bl.run("query", "node-overview", node_addr),
                    "node_overview", "nodeOverview") or {}
        out = []
        for row in ov.get("channels") or []:
            ch = row.get("channel", row)
            dest = row.get("destination") or {}
            peer = dest.get("chain_key") or dest.get("chainKey")
            if not peer or str(ch.get("status", "")).lower().startswith("closed"):
                continue
            out.append(dict(
                peer=to_checksum_address(peer),
                balance=ch.get("balance"),
                status=ch.get("status"),
                closure_time=parse_iso(ch.get("closure_time") or ch.get("closureTime")),
            ))
        return out, (ov.get("summary") or {})

    found, summary = outgoing()
    if summary:
        print(f"summary      {summary.get('open_count', '?')} open, "
              f"{summary.get('pending_to_close_count', '?')} closing, "
              f"{summary.get('closed_count', '?')} closed, "
              f"total {summary.get('total_balance', '?')}")

    print(f"\n{len(found)} open/closing outgoing channel(s)\n")
    hdr = f"  {'peer':<44}{'status':<18}{'balance':>20}  finalizable"
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    now = int(time.time())
    for c in found:
        fin = ""
        if is_pending(c["status"]):
            fin = ("now" if 0 < c["closure_time"] <= now else
                   f"in {(c['closure_time'] - now) // 60} min" if c["closure_time"]
                   else "?")
        print(f"  {c['peer']:<44}{str(c['status']):<18}"
              f"{fmt_hopr(c['balance']):>20}  {fin}")

    if args.list:
        return 0

    keep = {to_checksum_address(k) for k in args.keep}
    if args.finalize:
        targets = [c for c in found
                   if is_pending(c["status"]) and 0 < c["closure_time"] <= now]
        fn_sig = "finalizeOutgoingChannelClosure(address)"
        action = "finalize"
        if not targets:
            print("\nnothing is finalizable yet.")
            return 0
    else:
        if not keep:
            sys.exit("\n--keep 0xRELAY is required (the channel to preserve)")
        unknown = keep - {c["peer"] for c in found}
        if unknown:
            sys.exit(f"\n--keep names {', '.join(sorted(unknown))}, which is not an "
                     f"open channel.\nClosing everything else would leave the node "
                     f"with none. Refusing.")
        targets = [c for c in found if c["peer"] not in keep and is_open(c["status"])]
        fn_sig = "initiateOutgoingChannelClosure(address)"
        action = "initiate closure of"
        if not targets:
            print("\nnothing to close -- the channel set already matches --keep.")
            return 0

    print(f"\nwould {action} {len(targets)} channel(s):")
    for c in targets:
        print(f"  {c['peer']}   {fmt_hopr(c['balance'])}")
    print(f"  keeping: {', '.join(sorted(keep)) if keep else '(finalize phase)'}")

    # Unattended, nobody reads the plan before it runs. A cap turns "the node had
    # more channels than expected" from a swept set into a refusal.
    if len(targets) > args.max_close:
        sys.exit(f"\n{len(targets)} channels exceeds --max-close {args.max_close}. "
                 f"Raise it deliberately, or narrow --keep.")

    payloads = []
    for c in targets:
        inner = encode_channel_call(fn_sig, c["peer"])
        payloads.append((c, encode_exec_from_module(
            channels_addr, 0, inner, OPERATION_CALL)))
        print(f"\n  {c['peer']}\n    call:  0x{inner.hex()}"
              f"\n    outer: 0x{payloads[-1][1].hex()[:72]}…")

    if not args.send:
        print("\nDRY RUN -- nothing signed. Re-run with --send to submit.")
        return 0

    # ------------------------------------------------------------- sending --

    print(f"\nSubmitting {len(payloads)} transaction(s) from {acct.address}")
    print(f"audit log:   {args.audit_log}")
    audit = open(args.audit_log, "a", buffering=1)

    def record(event, **kv):
        audit.write("{}\t{}\t{}\n".format(
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), event,
            " ".join(f"{k}={v}" for k, v in kv.items())))

    record("plan", action=action.split()[0], count=len(payloads),
           signer=acct.address, chain=chain_id, channels=channels_addr,
           keep=",".join(sorted(keep)) or "-",
           peers=",".join(c["peer"] for c, _ in payloads))

    nonce = first_number(bl.run("query", "tx-count", acct.address))
    if nonce is None:
        sys.exit("blokli tx-count did not return a number; cannot build a transaction.")
    gas_price = (int(args.gas_price_gwei * 1e9) if args.gas_price_gwei
                 else int(info.get("gas_price") or info.get("gasPrice") or 0))
    if not gas_price:
        sys.exit("no gas price from chain-info; pass --gas-price-gwei.")
    print(f"nonce        {nonce}\ngas price    {gas_price / 1e9:.3f} gwei\n")

    state = {"nonce": nonce}

    def submit(c, payload, idx):
        tx = {"to": to_checksum_address(module_addr), "value": 0, "data": payload,
              "nonce": state["nonce"], "chainId": chain_id, "gas": args.gas_limit,
              "gasPrice": gas_price}
        signed = acct.sign_transaction(tx)
        raw = signed.raw_transaction
        raw_hex = "0x" + (raw.hex() if isinstance(raw, (bytes, bytearray)) else str(raw))
        # Recorded BEFORE broadcast: if this process dies before the answer, the
        # transaction is still on record and can be looked up. A log written only
        # on success cannot explain a half-finished run.
        record("sending", peer=c["peer"], nonce=state["nonce"], idx=idx)
        res = bl.run("tx", "--payload", raw_hex,
                     "--wait-for-confirmation", str(args.confirmations))
        record("sent", peer=c["peer"], nonce=state["nonce"],
               result=json.dumps(res)[:200] if res is not None else "-")
        print(f"  {c['peer']}  ->  "
              f"{json.dumps(res)[:110] if res is not None else 'submitted'}")
        state["nonce"] += 1

    # THE CANARY.
    #
    # Without an eth_call simulation the encoding is unproven against this
    # deployment, so the first close goes alone and the chain is re-read to
    # confirm that channel actually moved to PendingToClose. A wrong ABI costs
    # one transaction's gas and stops here; it cannot work through a whole
    # channel set doing nothing, or doing something else.
    start = 0
    if not args.no_canary and not args.finalize:
        c0, p0 = payloads[0]
        print("canary: first close sent alone, then verified on-chain")
        submit(c0, p0, 0)
        time.sleep(args.canary_settle)
        after = {x["peer"]: x for x in outgoing()[0]}
        st = after.get(c0["peer"], {}).get("status", "<no longer listed>")
        if not is_pending(st):
            record("canary-failed", peer=c0["peer"], status=str(st))
            sys.exit(
                f"\nCANARY FAILED: {c0['peer']} is still '{st}', not PendingToClose.\n"
                f"The transaction did not have the intended effect, so the remaining\n"
                f"{len(payloads) - 1} channel(s) were NOT touched. Check the ABI\n"
                f"against the deployed HoprChannels; the audit log has what was sent."
            )
        record("canary-ok", peer=c0["peer"], status=str(st))
        print(f"  canary OK: {c0['peer']} is now {st}\n")
        start = 1

    for i, (c, payload) in enumerate(payloads[start:], start=start):
        submit(c, payload, i)

    record("done", action=action.split()[0], count=len(payloads))

    if not args.finalize:
        print(f"\nClosures initiated. Finalize after the {grace}s grace period:")
        print("  ./tools/close-channels.py --list")
        print("  ./tools/close-channels.py --finalize --send")
    else:
        print("\nDone. Verify the pin took before running a study:")
        print("  sudo ./bench/use-arm.sh <pin-cfg arm> --count   # must read 1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
