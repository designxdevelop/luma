// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Strict single-request HTTP/1.1 server for the webhook API. Deliberately uses sockets
// instead of node:http: its parser is more permissive than our framing rules allow.
// Ported from the Mac WebhookHTTPParser; auth is decided as soon as the headers are complete.

import { createServer as createTcpServer, type Server, type Socket } from 'node:net';
import { createServer as createTlsServer } from 'node:tls';
import type { WebhookIdentity } from './certificate';
import { timingSafeEqual } from 'node:crypto';
import { LumaError } from './model';

export const HEADER_LIMIT = 16 * 1024;
export const BODY_LIMIT = 64 * 1024;
const MAX_CONNECTIONS = 16;
const CONNECTION_DEADLINE_MS = 10_000;
const LINGER_MS = 1_000;

export interface HttpRequest { method: string; path: string; body: Buffer }
export interface HttpResponse { status: number; body: unknown }
export type ParseResult =
  | { kind: 'incomplete' }
  | { kind: 'request'; request: HttpRequest }
  | { kind: 'failure'; response: HttpResponse };

const REASONS: Record<number, string> = {
  200: 'OK', 202: 'Accepted', 400: 'Bad Request', 401: 'Unauthorized', 404: 'Not Found',
  405: 'Method Not Allowed', 408: 'Request Timeout', 409: 'Conflict', 411: 'Length Required',
  413: 'Content Too Large', 415: 'Unsupported Media Type', 431: 'Request Header Fields Too Large',
  500: 'Internal Server Error', 503: 'Service Unavailable',
};

const TCHAR = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
const PRINTABLE_HEAD = /^[\t\r\n\x20-\x7e]*$/;
const HEADER_VALUE = /^[\t\x20-\x7e]*$/;
const PATH = /^\/(?!\/)[\x21-\x7e]*$/;
const CRLF2 = Buffer.from('\r\n\r\n');
const utf8 = new TextDecoder('utf-8', { fatal: true });

const failure = (status: number, message: string): ParseResult => ({ kind: 'failure', response: { status, body: { error: message } } });

/** Compares without leaking the length or content through early exit. */
function secretEqual(actual: string, expected: string): boolean {
  const a = Buffer.from(actual), e = Buffer.from(expected);
  if (a.length !== e.length) { timingSafeEqual(e, e); return false; }
  return timingSafeEqual(a, e);
}

export class RequestParser {
  private buffer: Buffer = Buffer.alloc(0);
  private head?: { method: string; path: string; bodyLength: number };
  private finished = false;

  constructor(private readonly token: string) {}

  append(chunk: Buffer): ParseResult {
    if (this.finished) return failure(400, 'Only one request is allowed');
    // Bound allocation even if a caller supplies one oversized frame.
    if (chunk.length > HEADER_LIMIT + BODY_LIMIT - this.buffer.length) return this.fail(this.head ? 413 : 431, 'Request too large');
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (!this.head) {
      const separator = this.buffer.indexOf(CRLF2);
      if (separator < 0) return this.buffer.length > HEADER_LIMIT ? this.fail(431, 'Headers too large') : { kind: 'incomplete' };
      if (separator + 4 > HEADER_LIMIT) return this.fail(431, 'Headers too large');
      const outcome = this.parseHead(separator);
      if (outcome) return outcome;
    }
    const head = this.head!;
    if (this.buffer.length > head.bodyLength) return this.fail(400, 'Trailing bytes or pipelined requests are not supported');
    if (this.buffer.length < head.bodyLength) return { kind: 'incomplete' };
    try { utf8.decode(this.buffer); } catch { return this.fail(400, 'Body must be valid UTF-8'); }
    this.finished = true;
    return { kind: 'request', request: { method: head.method, path: head.path, body: this.buffer } };
  }

  /** Validates the header block; returns a failure, or undefined after storing `head` and trimming the buffer. */
  private parseHead(separator: number): ParseResult | undefined {
    const text = this.buffer.subarray(0, separator).toString('latin1');
    if (!PRINTABLE_HEAD.test(text)) return this.fail(400, 'Invalid headers');
    const lines = text.split('\r\n');
    const first = (lines[0] ?? '').split(' ');
    if (first.length !== 3 || first[2] !== 'HTTP/1.1') return this.fail(400, 'HTTP/1.1 required');
    const method = first[0]!, path = first[1]!;
    if (!PATH.test(path) || /[?#\\]/.test(path)) return this.fail(400, 'Use an absolute path without a query string');
    const fields = new Map<string, string>();
    for (const line of lines.slice(1)) {
      const colon = line.indexOf(':');
      if (colon <= 0) return this.fail(400, 'Malformed header');
      const name = line.slice(0, colon);
      if (!TCHAR.test(name)) return this.fail(400, 'Invalid header name');
      const key = name.toLowerCase();
      if (fields.has(key)) return this.fail(400, 'Duplicate header');
      const value = line.slice(colon + 1).replace(/^[ \t]+|[ \t]+$/g, '');
      if (!HEADER_VALUE.test(value)) return this.fail(400, 'Invalid header value');
      fields.set(key, value);
    }
    const host = fields.get('host');
    if (!host || /[, \t]/.test(host)) return this.fail(400, 'Host required');
    for (const banned of ['transfer-encoding', 'expect', 'upgrade', 'trailer']) {
      if (fields.has(banned)) return this.fail(400, 'Unsupported HTTP framing');
    }
    // Auth precedes everything that depends on the client's claims about the body.
    if (this.token === '' || !secretEqual(fields.get('authorization') ?? '', `Bearer ${this.token}`)) {
      return this.fail(401, 'Bearer authentication required');
    }
    let bodyLength = 0;
    const lengthField = fields.get('content-length');
    if (lengthField !== undefined) {
      if (!/^[0-9]+$/.test(lengthField)) return this.fail(400, 'Invalid Content-Length');
      bodyLength = Number(lengthField); // huge digit strings become large floats, never wrapping
      if (bodyLength > BODY_LIMIT) return this.fail(413, 'Body too large');
    }
    if (method !== 'GET' && method !== 'POST') return this.fail(405, 'Use GET or POST');
    if (method === 'POST') {
      if (lengthField === undefined) return this.fail(411, 'Content-Length required');
      const [type, ...params] = (fields.get('content-type') ?? '').split(';');
      if (type!.trim().toLowerCase() !== 'application/json') return this.fail(415, 'Content-Type must be application/json');
      for (const param of params) {
        if (param.trim().toLowerCase().replaceAll('"', '') !== 'charset=utf-8') return this.fail(415, 'Only UTF-8 JSON is supported');
      }
    } else if (bodyLength !== 0) {
      return this.fail(400, 'GET body is not supported');
    }
    this.head = { method, path, bodyLength };
    this.buffer = this.buffer.subarray(separator + 4);
    return undefined;
  }

  private fail(status: number, message: string): ParseResult {
    this.finished = true;
    this.buffer = Buffer.alloc(0);
    return failure(status, message);
  }
}

function wire(response: HttpResponse): Buffer {
  const status = Number.isInteger(response.status) && response.status >= 100 && response.status <= 599 ? response.status : 500;
  const body = Buffer.from(JSON.stringify(response.body) ?? 'null');
  const head = `HTTP/1.1 ${status} ${REASONS[status] ?? 'Response'}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n`;
  return Buffer.concat([Buffer.from(head), body]);
}

export interface WebhookStartOptions {
  port: number;
  allowLAN: boolean;
  token: string;
  /** Plain TCP is exclusively for parser and framing tests; the app always supplies an identity. */
  tls: Pick<WebhookIdentity, 'key' | 'cert'> | { testOnlyPlainTcp: true };
  handler: (req: HttpRequest) => Promise<HttpResponse>;
  /** Per-connection deadline; defaults to 10 s. Tests shorten it. */
  deadlineMs?: number;
}

/** Loopback-only unless LAN access is explicitly enabled. */
export class WebhookServer {
  private server?: Server;
  private readonly sockets = new Set<Socket>();
  private boundPort?: number;

  get running(): boolean { return this.server !== undefined; }
  get port(): number | undefined { return this.boundPort; }

  async start(options: WebhookStartOptions): Promise<{ port: number; host: string }> {
    const { port, allowLAN, token, handler } = options;
    const deadline = options.deadlineMs ?? CONNECTION_DEADLINE_MS;
    if (!/^[\x21-\x7e]{16,}$/.test(token)) throw new LumaError('Webhook token must be at least 16 visible ASCII characters.');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new LumaError('Webhook port must be 0–65535.');
    await this.stop();
    const host = allowLAN ? '0.0.0.0' : '127.0.0.1';
    // allowHalfOpen lets a client that shuts down its write side still receive the response.
    const server = 'testOnlyPlainTcp' in options.tls
      ? createTcpServer({ allowHalfOpen: true }, (socket) => this.accept(socket, token, handler, deadline))
      : createTlsServer({ ...options.tls, minVersion: 'TLSv1.2', handshakeTimeout: deadline, allowHalfOpen: true }, (socket) => this.accept(socket, token, handler, deadline));
    server.maxConnections = MAX_CONNECTIONS;
    // Track pre-handshake sockets as well, so stop closes stalled TLS connections.
    // Every raw connection also gets a hard lifetime: handshakeTimeout only emits
    // tlsClientError, so silent clients could otherwise hold all slots.
    server.on('connection', (socket) => {
      this.sockets.add(socket);
      const cap = setTimeout(() => socket.destroy(), deadline + LINGER_MS);
      socket.on('close', () => { clearTimeout(cap); this.sockets.delete(socket); });
    });
    server.on('tlsClientError', (_error, socket) => socket.destroy());
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, host, () => { server.off('error', reject); resolve(); });
    }).catch((error: NodeJS.ErrnoException) => {
      server.close();
      if (error.code === 'EADDRINUSE') throw new LumaError(`Port ${port} is in use. Choose another port or quit the app using it.`);
      if (error.code === 'EACCES') throw new LumaError(`Port ${port} needs elevated permission. Choose a port above 1023.`);
      throw new LumaError(`Webhook server could not start: ${error.message}`);
    });
    server.on('error', () => undefined);
    this.server = server;
    const address = server.address();
    this.boundPort = typeof address === 'object' && address ? address.port : port;
    return { port: this.boundPort, host };
  }

  async stop(): Promise<void> {
    const server = this.server;
    this.server = undefined;
    this.boundPort = undefined;
    for (const socket of this.sockets) socket.destroy();
    this.sockets.clear();
    if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  private accept(socket: Socket, token: string, handler: WebhookStartOptions['handler'], deadline: number): void {
    this.sockets.add(socket);
    socket.setNoDelay(true);
    socket.on('error', () => socket.destroy());
    const parser = new RequestParser(token);
    let responding = false;
    let timer: NodeJS.Timeout | undefined = setTimeout(() => {
      if (responding) socket.destroy(); else respond({ status: 408, body: { error: 'Request timed out' } });
    }, deadline);
    socket.on('close', () => { clearTimeout(timer); this.sockets.delete(socket); });
    // Keep draining after replying early (e.g. 401 mid-upload) so closing doesn't RST the response away.
    const respond = (response: HttpResponse): void => {
      if (socket.destroyed) return;
      responding = true;
      clearTimeout(timer);
      timer = setTimeout(() => socket.destroy(), LINGER_MS);
      socket.end(wire(response));
    };
    socket.on('end', () => { if (!responding) socket.destroy(); });
    socket.on('data', (chunk: Buffer) => {
      if (responding) return;
      const result = parser.append(chunk);
      if (result.kind === 'incomplete') return;
      if (result.kind === 'failure') { respond(result.response); return; }
      responding = true; // handler is running; ignore further input until it answers
      handler(result.request).then(
        (response) => { responding = false; respond(response); },
        () => { responding = false; respond({ status: 500, body: { error: 'Internal error' } }); },
      );
    });
  }
}
