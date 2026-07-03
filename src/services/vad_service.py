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
    """Shared Silero v5 ONNX session. The recurrent LSTM state is per-CONNECTION, held by the
    caller (see VADState), NOT on this object — Silero v5 takes a single combined `state` tensor
    (2, 1, 128) and returns the next state, unlike v4's separate h/c (2, 1, 64)."""

    def __init__(self, model_path: str, threshold: float = 0.5):
        self.threshold = threshold
        opts = ort.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        self.session = ort.InferenceSession(model_path, sess_options=opts)
        self._sr = np.array(SAMPLE_RATE, dtype=np.int64)

    def infer(self, contexted_audio: np.ndarray, state: np.ndarray):
        """Run one frame (64-sample context + 512 new = 576 samples) through the v5 model.
        Returns (prob, new_state). The 64-sample context is REQUIRED — Silero v5 outputs
        near-zero probabilities for bare 512-sample frames without it."""
        audio_tensor = contexted_audio.reshape(1, -1).astype(np.float32)
        try:
            output, state_new = self.session.run(
                None, {'input': audio_tensor, 'state': state, 'sr': self._sr}
            )
            return float(output[0][0]), state_new
        except Exception as e:
            print(f"[VAD] Inference error: {e}", file=sys.stderr)
            return 0.0, state


class VADState:
    """Per-connection recurrent state + context so concurrent clients don't corrupt each other."""
    CONTEXT = 64

    def __init__(self, vad: 'SileroVAD'):
        self.vad = vad
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.context = np.zeros(self.CONTEXT, dtype=np.float32)

    def is_speech(self, audio: np.ndarray) -> bool:
        if len(audio) != WINDOW_SIZE:
            return False
        contexted = np.concatenate([self.context, audio])   # 64 + 512 = 576
        prob, self.state = self.vad.infer(contexted, self.state)
        self.context = audio[-self.CONTEXT:].copy()
        return prob > self.vad.threshold


def handle_client(conn, vad):
    """Handle one client connection with its OWN recurrent state."""
    buffer = b''
    frame_bytes = WINDOW_SIZE * 4  # float32 = 4 bytes
    state = VADState(vad)

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
                is_speech = state.is_speech(samples)
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
