# A minimal Chrome DevTools Protocol client (stdlib only), for the memory benches:
#   cdp.py <page websocket URL> <method> [params as JSON]
import base64, json, os, socket, sys, struct
from urllib.parse import urlparse

def ws_connect(url):
    u = urlparse(url)
    s = socket.create_connection((u.hostname, u.port), timeout=20)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    return s

def send(s, text):
    data = text.encode(); mask = os.urandom(4)
    head = bytes([0x81])
    n = len(data)
    head += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def recv_exact(s, n):
    b = b""
    while len(b) < n:
        b += s.recv(n - len(b))
    return b

def recv(s):
    h = recv_exact(s, 2); n = h[1] & 0x7F
    if n == 126: n = struct.unpack(">H", recv_exact(s, 2))[0]
    elif n == 127: n = struct.unpack(">Q", recv_exact(s, 8))[0]
    return recv_exact(s, n).decode(errors="replace")

s = ws_connect(sys.argv[1])
send(s, json.dumps({"id": 1, "method": sys.argv[2], "params": json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}}))
while True:
    m = json.loads(recv(s))
    if m.get("id") == 1:
        print(json.dumps(m)[:1500]); break
