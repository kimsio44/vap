#!/usr/bin/env python3
"""
test_signaling.py â€” Teste le signaling server RemoteDesk

Simule un handshake complet hÃ´te + client :
  1. L'hÃ´te se connecte et enregistre une session
  2. Le client rejoint la session
  3. Ã‰change simulÃ© de SDP Offer/Answer + ICE candidates

Usage:
    python test_signaling.py
    python test_signaling.py --url ws://your-server:8080
"""

import asyncio
import json
import argparse
import websockets
from datetime import datetime

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
RESET  = "\033[0m"

def log(color, tag, msg):
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"{color}[{ts}] [{tag}] {msg}{RESET}")

def ok(tag, msg):   log(GREEN,  f"âœ“ {tag}", msg)
def err(tag, msg):  log(RED,    f"âœ— {tag}", msg)
def info(tag, msg): log(BLUE,   f"  {tag}", msg)
def warn(tag, msg): log(YELLOW, f"âš  {tag}", msg)


async def run_host(url: str, results: dict):
    """Simule le comportement de l'hÃ´te"""
    async with websockets.connect(url) as ws:
        info("HOST", f"Connected to {url}")

        # 1. Enregistrer une session avec un code fixe pour le test
        register_msg = {
            "type": "register",
            "session_code": "123-456",
        
            "role": "host"
        }
        await ws.send(json.dumps(register_msg))
        info("HOST", f"Sent: {register_msg}")

        # 2. Attendre la confirmation d'enregistrement
        resp = json.loads(await ws.recv())
        info("HOST", f"Received: {resp}")

        if resp.get("type") == "registered":
            ok("HOST", f"Registered! peer_id={resp['peer_id']}, code={resp['session_code']}")
            results["host_peer_id"] = resp["peer_id"]
            results["host_registered"] = True
        else:
            err("HOST", f"Expected 'registered', got: {resp}")
            results["host_registered"] = False
            return

        # 3. Attendre que le client rejoigne
        info("HOST", "Waiting for client to join...")
        notif = json.loads(await ws.recv())
        info("HOST", f"Received: {notif}")

        if notif.get("type") == "peer_joined":
            ok("HOST", f"Client joined! client_peer_id={notif['peer_id']}")
            results["client_peer_id_from_host"] = notif["peer_id"]
            results["peer_joined"] = True
        else:
            err("HOST", f"Expected 'peer_joined', got: {notif}")
            results["peer_joined"] = False
            return

        # 4. Attendre le SDP Offer du client
        sdp_offer = json.loads(await ws.recv())
        if sdp_offer.get("type") == "sdp_offer":
            ok("HOST", f"Got SDP Offer from {sdp_offer['from_id'][:8]}...")
            results["sdp_offer_received"] = True
        else:
            err("HOST", f"Expected 'sdp_offer', got: {sdp_offer}")
            results["sdp_offer_received"] = False
            return

        # 5. RÃ©pondre avec un SDP Answer
        answer_msg = {
            "type": "sdp_answer",
            "target_id": results["client_peer_id_from_host"],
            "sdp": "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\n[FAKE ANSWER SDP]"
        }
        await ws.send(json.dumps(answer_msg))
        ok("HOST", "Sent SDP Answer")

        # 6. Attendre ICE candidate du client
        ice = json.loads(await ws.recv())
        if ice.get("type") == "ice_candidate":
            ok("HOST", f"Got ICE candidate from client")
            results["ice_received_by_host"] = True
        else:
            warn("HOST", f"Expected 'ice_candidate', got: {ice}")
            results["ice_received_by_host"] = False

        results["host_completed"] = True
        info("HOST", "Host flow completed âœ“")


async def run_client(url: str, results: dict):
    """Simule le comportement du client"""
    # Attendre que l'hÃ´te soit prÃªt
    await asyncio.sleep(0.3)

    async with websockets.connect(url) as ws:
        info("CLIENT", f"Connected to {url}")

        # 1. Rejoindre la session
        join_msg = {
            "type": "join",
            "session_code": "123-456"
        }
        await ws.send(json.dumps(join_msg))
        info("CLIENT", f"Sent: {join_msg}")

        # 2. Attendre la confirmation
        resp = json.loads(await ws.recv())
        info("CLIENT", f"Received: {resp}")

        if resp.get("type") == "registered":
            ok("CLIENT", f"Joined session! peer_id={resp['peer_id']}")
            results["client_registered"] = True
        else:
            err("CLIENT", f"Expected 'registered', got: {resp}")
            results["client_registered"] = False
            return

        # 3. Envoyer un SDP Offer Ã  l'hÃ´te
        offer_msg = {
            "type": "sdp_offer",
            "target_id": results.get("host_peer_id", ""),
            "sdp": "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\n[FAKE OFFER SDP]"
        }
        await ws.send(json.dumps(offer_msg))
        ok("CLIENT", "Sent SDP Offer to host")

        # 4. Attendre le SDP Answer de l'hÃ´te
        answer = json.loads(await ws.recv())
        if answer.get("type") == "sdp_answer":
            ok("CLIENT", f"Got SDP Answer from host")
            results["sdp_answer_received"] = True
        else:
            err("CLIENT", f"Expected 'sdp_answer', got: {answer}")
            results["sdp_answer_received"] = False
            return

        # 5. Envoyer un ICE candidate
        ice_msg = {
            "type": "ice_candidate",
            "target_id": results.get("host_peer_id", ""),
            "candidate": {
                "candidate": "candidate:1 1 UDP 2122260223 192.168.1.100 54400 typ host",
                "sdp_mid": "0",
                "sdp_mline_index": 0
            }
        }
        await ws.send(json.dumps(ice_msg))
        ok("CLIENT", "Sent ICE candidate to host")

        results["client_completed"] = True
        info("CLIENT", "Client flow completed âœ“")


async def main(url: str):
    print(f"\n{BLUE}{'='*60}")
    print(f"  RemoteDesk Signaling Server â€” Test Suite")
    print(f"  Target: {url}")
    print(f"{'='*60}{RESET}\n")

    results = {}

    # Lancer hÃ´te et client en parallÃ¨le
    await asyncio.gather(
        run_host(url, results),
        run_client(url, results),
    )

    # Rapport
    print(f"\n{BLUE}{'='*60}")
    print(f"  Test Results")
    print(f"{'='*60}{RESET}")

    checks = [
        ("host_registered",       "HÃ´te enregistre sa session"),
        ("peer_joined",           "HÃ´te notifiÃ© du join client"),
        ("client_registered",     "Client rejoint la session"),
        ("sdp_offer_received",    "SDP Offer transmis hÃ´teâ†’client"),
        ("sdp_answer_received",   "SDP Answer transmis clientâ†’hÃ´te"),
        ("ice_received_by_host",  "ICE candidate relayÃ©"),
        ("host_completed",        "Flow hÃ´te complet"),
        ("client_completed",      "Flow client complet"),
    ]

    passed = 0
    for key, label in checks:
        val = results.get(key, False)
        if val:
            print(f"  {GREEN}âœ“ {label}{RESET}")
            passed += 1
        else:
            print(f"  {RED}âœ— {label}{RESET}")

    print(f"\n{GREEN if passed == len(checks) else RED}  {passed}/{len(checks)} tests passed{RESET}\n")

    return passed == len(checks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="ws://127.0.0.1:8080")
    args = parser.parse_args()

    success = asyncio.run(main(args.url))
    exit(0 if success else 1)

