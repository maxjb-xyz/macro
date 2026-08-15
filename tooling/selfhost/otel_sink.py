#!/usr/bin/env python3
"""Minimal OTLP sink — accepts and discards trace/log exports.

The self-host stack ships no observability backend by default, but the
Cloudflare Worker services (sync-service, ai-editing-worker) and the analytics
proxy are configured to export OTLP to `otel-collector:4318` — a network alias
that only exists under the jaeger/datadog profiles. With no collector, their
span flushes fail with "DNS lookup failed" and spam the logs every few seconds.

This service provides the `otel-collector` alias and 200s every request so the
workers stay quiet. It discards the data; wire a real collector (and point
OTEL_EXPORTER_OTLP_ENDPOINT at it) when observability is actually wanted.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass


HTTPServer(("0.0.0.0", 4318), Handler).serve_forever()
