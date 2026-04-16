#!/usr/bin/env python3
"""
OmniPilot VAD Service — Silero Voice Activity Detection
Runs as a local TCP server that receives audio and returns speech/silence status.
Protocol: Send 960 bytes (480 float16 samples = 30ms at 16kHz), receive b'1' or b'0'
"""

import socket
import struct
import threading
import numpy as np
import onnxruntime as ort
import os
import sys
import signal

MODEL_PATH = os.path.join(os.path.dirname(__file__), '..', '..', 'models', 'silero_vad.onnx')
HOST = '127.0.0.1'
PORT = 18384
SAMPLE_RATE = 16000
WINDOW_SIZE = 512  # Silero v5 expects 512 samples (32ms at 16kHz)


class SileroVAD:
    def __init__(self, model_path: str, threshold: float = 0.5):
        self.threshold = threshold
        opts = ort.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        self.session = ort.InferenceSession(model_path, sess_options=opts)
        self.reset()

    def reset(self):
        self._h = np.zeros((2, 1, 64), dtype=np.float32)
        self._c = np.zeros((2, 1, 64), dtype=np.float32)

    def process(self, audio: np.ndarray) -> float:
        """Process a 512-sample frame, return speech probability (0-1)."""
        if len(audio) != WINDOW_SIZE:
            return 0.0

        audio_tensor = audio.reshape(1, -1).astype(np.float32)
        sr = np.array([SAMPLE_RATE], dtype=np.int64)

        ort_inputs = {
            'input': audio_tensor,
            'h': self._h,
            'c': self._c,
            'sr': sr,
        }

        try:
            output, h_new, c_new = self.session.run(None, ort_inputs)
            self._h = h_new
            self._c = c_new
            return float(output[0][0])
        except Exception as e:
            print(f"[VAD] Inference error: {e}", file=sys.stderr)
            return 0.0

    def is_speech(self, audio: np.ndarray) -> bool:
        return self.process(audio) > self.threshold


def handle_client(conn, vad):
    """Handle one client connection."""
    buffer = b''
    frame_bytes = WINDOW_SIZE * 4  # float32 = 4 bytes

    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break

            buffer += data

            while len(buffer) >= frame_bytes:
                frame_data = buffer[:frame_bytes]
                buffer = buffer[frame_bytes:]

                samples = np.frombuffer(frame_data, dtype=np.float32)
                is_speech = vad.is_speech(samples)
                conn.sendall(b'1' if is_speech else b'0')

    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        conn.close()


def main():
    if not os.path.exists(MODEL_PATH):
        print(f"[VAD] Model not found: {MODEL_PATH}", file=sys.stderr)
        sys.exit(1)

    print(f"[VAD] Loading Silero VAD model...")
    vad = SileroVAD(MODEL_PATH, threshold=0.45)
    print(f"[VAD] Model loaded. Starting server on {HOST}:{PORT}")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(2)

    def shutdown(sig, frame):
        print("\n[VAD] Shutting down...")
        server.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print(f"[VAD] Ready. Listening for connections...")

    while True:
        try:
            conn, addr = server.accept()
            thread = threading.Thread(target=handle_client, args=(conn, vad), daemon=True)
            thread.start()
        except OSError:
            break


if __name__ == '__main__':
    main()
