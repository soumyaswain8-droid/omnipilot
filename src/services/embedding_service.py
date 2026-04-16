#!/usr/bin/env python3
"""
OmniPilot Embedding Service — Generates 384-dim vectors for semantic search
Runs as a local HTTP server on port 18385.
POST /embed {"text": "..."} -> {"embedding": [...384 floats...]}
POST /search {"query": "...", "db_path": "..."} -> {"results": [...]}
"""

import json
import os
import sys
import signal
import sqlite3
import struct
from http.server import HTTPServer, BaseHTTPRequestHandler

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

MODEL_DIR = os.path.join(os.path.dirname(__file__), '..', '..', 'models')
MODEL_PATH = os.path.join(MODEL_DIR, 'minilm_model.onnx')
TOKENIZER_PATH = os.path.join(MODEL_DIR, 'minilm_tokenizer.json')
HOST = '127.0.0.1'
PORT = 18385


class EmbeddingEngine:
    def __init__(self):
        print("[Embed] Loading MiniLM model...")
        opts = ort.SessionOptions()
        opts.inter_op_num_threads = 2
        opts.intra_op_num_threads = 2
        self.session = ort.InferenceSession(MODEL_PATH, sess_options=opts)
        self.tokenizer = Tokenizer.from_file(TOKENIZER_PATH)
        self.tokenizer.enable_truncation(max_length=128)
        self.tokenizer.enable_padding(length=128)
        print("[Embed] Model loaded. 384-dim embeddings ready.")

    def embed(self, text: str) -> list:
        """Generate a 384-dim embedding for text."""
        encoded = self.tokenizer.encode(text)
        input_ids = np.array([encoded.ids], dtype=np.int64)
        attention_mask = np.array([encoded.attention_mask], dtype=np.int64)
        token_type_ids = np.zeros_like(input_ids)

        outputs = self.session.run(None, {
            'input_ids': input_ids,
            'attention_mask': attention_mask,
            'token_type_ids': token_type_ids,
        })

        # Mean pooling over token embeddings
        token_embeddings = outputs[0][0]  # (seq_len, 384)
        mask = attention_mask[0].astype(np.float32)
        mask_expanded = np.expand_dims(mask, -1)  # (seq_len, 1)
        summed = np.sum(token_embeddings * mask_expanded, axis=0)
        counted = np.maximum(np.sum(mask), 1e-9)
        embedding = summed / counted

        # L2 normalize
        norm = np.linalg.norm(embedding)
        if norm > 0:
            embedding = embedding / norm

        return embedding.tolist()

    def cosine_similarity(self, a: list, b: list) -> float:
        a, b = np.array(a), np.array(b)
        return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))


engine = None


def float_list_to_blob(floats: list) -> bytes:
    """Pack float list into bytes for SQLite BLOB storage."""
    return struct.pack(f'{len(floats)}f', *floats)


def blob_to_float_list(blob: bytes) -> list:
    """Unpack bytes BLOB to float list."""
    n = len(blob) // 4
    return list(struct.unpack(f'{n}f', blob))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # Suppress request logs

    def do_GET(self):
        if self.path == '/health':
            self._respond(200, {'status': 'ok', 'model': 'all-MiniLM-L6-v2', 'dim': 384})
        else:
            self._respond(404, {'error': 'not found'})

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if self.path == '/embed':
            text = body.get('text', '')
            if not text:
                self._respond(400, {'error': 'text required'})
                return
            embedding = engine.embed(text)
            self._respond(200, {'embedding': embedding, 'dim': len(embedding)})

        elif self.path == '/embed_and_store':
            # Embed text and store in SQLite memory DB
            text = body.get('text', '')
            memory_id = body.get('memory_id', 0)
            db_path = body.get('db_path', '')
            if not all([text, memory_id, db_path]):
                self._respond(400, {'error': 'text, memory_id, db_path required'})
                return
            embedding = engine.embed(text)
            blob = float_list_to_blob(embedding)
            try:
                conn = sqlite3.connect(db_path)
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS memory_embeddings (
                        memory_id INTEGER PRIMARY KEY,
                        embedding BLOB NOT NULL
                    )
                """)
                conn.execute(
                    "INSERT OR REPLACE INTO memory_embeddings (memory_id, embedding) VALUES (?, ?)",
                    (memory_id, blob)
                )
                conn.commit()
                conn.close()
                self._respond(200, {'stored': True, 'memory_id': memory_id})
            except Exception as e:
                self._respond(500, {'error': str(e)})

        elif self.path == '/search':
            # Semantic search: embed query, compare against stored embeddings
            query = body.get('query', '')
            db_path = body.get('db_path', '')
            limit = body.get('limit', 5)
            if not all([query, db_path]):
                self._respond(400, {'error': 'query, db_path required'})
                return
            try:
                query_emb = engine.embed(query)
                conn = sqlite3.connect(db_path)

                # Get all embeddings
                rows = conn.execute("""
                    SELECT e.memory_id, e.embedding, m.content, m.timestamp
                    FROM memory_embeddings e
                    JOIN memories m ON e.memory_id = m.id
                """).fetchall()
                conn.close()

                # Compute similarities
                results = []
                for mid, blob, content, ts in rows:
                    emb = blob_to_float_list(blob)
                    score = engine.cosine_similarity(query_emb, emb)
                    results.append({'id': mid, 'content': content, 'timestamp': ts, 'score': score})

                results.sort(key=lambda x: x['score'], reverse=True)
                self._respond(200, {'results': results[:limit]})
            except Exception as e:
                self._respond(500, {'error': str(e)})

        elif self.path == '/health':
            self._respond(200, {'status': 'ok', 'model': 'all-MiniLM-L6-v2', 'dim': 384})

        else:
            self._respond(404, {'error': 'not found'})

    def _respond(self, code, data):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())


def main():
    global engine

    if not os.path.exists(MODEL_PATH):
        print(f"[Embed] Model not found: {MODEL_PATH}", file=sys.stderr)
        sys.exit(1)

    engine = EmbeddingEngine()

    server = HTTPServer((HOST, PORT), Handler)
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

    print(f"[Embed] Server running on {HOST}:{PORT}")
    server.serve_forever()


if __name__ == '__main__':
    main()
