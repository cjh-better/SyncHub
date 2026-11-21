"""
Network Fault Injection Utilities for SyncHub-Next E2E Testing.
Simulates TCP resets, Keep-Alive socket aborts, slow-loris drip, and network flapping.
"""

import socket
import time
from typing import Optional


class NetworkFaultInjector:
    @staticmethod
    def send_truncated_http_upload(host: str, port: int, path: str, total_length: int, send_bytes: int, headers: Optional[dict] = None) -> (int, str):
        """
        Sends an HTTP upload with Content-Length: total_length, but terminates the TCP stream
        after sending only send_bytes, simulating a network drop mid-transfer.
        """
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect((host, port))

        req_lines = [
            f"POST {path} HTTP/1.1",
            f"Host: {host}:{port}",
            f"Content-Length: {total_length}",
            "Content-Type: application/octet-stream",
            "Connection: keep-alive"
        ]
        if headers:
            for k, v in headers.items():
                req_lines.append(f"{k}: {v}")
        req_lines.append("\r\n")
        req_header = "\r\n".join(req_lines).encode("utf-8")
        s.sendall(req_header)

        # Send partial body
        partial_data = b"X" * send_bytes
        s.sendall(partial_data)

        # Abruptly close socket (TCP FIN/RST simulation)
        s.close()
        return 0, "Aborted"

    @staticmethod
    def send_slow_loris_stream(host: str, port: int, path: str, byte_interval: float = 0.5, max_bytes: int = 5) -> socket.socket:
        """
        Simulates slow dripping stream to test read timeouts.
        """
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10.0)
        s.connect((host, port))
        req = (
            f"POST {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Content-Length: 1000\r\n"
            f"Content-Type: application/octet-stream\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        for _ in range(max_bytes):
            s.sendall(b"A")
            time.sleep(byte_interval)
        return s

    @staticmethod
    def trigger_socket_abort(sock: socket.socket):
        """
        Forces a hard TCP RST by enabling linger with timeout 0.
        """
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, bytes([1, 0, 0, 0]))
            sock.close()
        except Exception:
            pass
