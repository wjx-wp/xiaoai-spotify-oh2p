package io.xiaoaimusic.handoff;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

final class OAuthCallbackServer implements Closeable {
    private static final int MAX_HEADER_BYTES = 8_192;
    // Android short-service foreground work is limited to roughly three minutes.
    // Leave a safety margin for service teardown, but give the user enough time to
    // sign in and review Spotify's consent page before the loopback listener closes.
    static final long TOTAL_TIMEOUT_MS = TimeUnit.SECONDS.toMillis(150L);
    private final ServerSocket server;
    private final String expectedState;

    OAuthCallbackServer(String expectedState) throws IOException {
        this.expectedState = expectedState;
        server = new ServerSocket();
        server.setReuseAddress(false);
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 43_827), 1);
    }

    String awaitCode() throws Exception {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TOTAL_TIMEOUT_MS);
        try {
            while (true) {
                long remainingNanos = deadline - System.nanoTime();
                if (remainingNanos <= 0L) throw new java.net.SocketTimeoutException(
                        "Spotify OAuth callback timed out");
                long remainingMs = Math.max(1L, TimeUnit.NANOSECONDS.toMillis(remainingNanos));
                server.setSoTimeout((int) Math.min(Integer.MAX_VALUE, remainingMs));
                try (Socket socket = server.accept()) {
                    if (!socket.getInetAddress().isLoopbackAddress()) continue;
                    OAuthCallbackParser.Result result;
                    try {
                        String header = readHeader(socket, deadline);
                        result = OAuthCallbackParser.parse(header, expectedState);
                    } catch (IOException invalidRequest) {
                        continue;
                    }
                    if (!result.isSuccess()) {
                        try {
                            respond(socket.getOutputStream(), 400,
                                    "这个回调没有被接受；请只使用当前 Spotify 授权页面。");
                        } catch (IOException ignored) {
                            // A local probe may close before reading; it does not own the callback.
                        }
                        if (result.terminal()) throw new SecurityException(result.error());
                        continue;
                    }
                    try {
                        respond(socket.getOutputStream(), 200,
                                "授权回调已收到。请返回“小爱 Spotify 接管”查看安全下发结果。");
                    } catch (IOException ignored) {
                        // The valid code remains usable even if the browser closes immediately.
                    }
                    return result.code();
                }
            }
        } finally {
            close();
        }
    }

    private static String readHeader(Socket socket, long deadlineNanos) throws IOException {
        InputStream input = socket.getInputStream();
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int matched = 0;
        while (bytes.size() < MAX_HEADER_BYTES) {
            long remainingNanos = deadlineNanos - System.nanoTime();
            if (remainingNanos <= 0L) {
                throw new java.net.SocketTimeoutException("OAuth callback header timed out");
            }
            long remainingMs = Math.max(1L, TimeUnit.NANOSECONDS.toMillis(remainingNanos));
            socket.setSoTimeout((int) Math.min(5_000L, remainingMs));
            int value = input.read();
            if (value < 0) throw new IOException("OAuth callback ended early");
            bytes.write(value);
            matched = switch (matched) {
                case 0 -> value == '\r' ? 1 : 0;
                case 1 -> value == '\n' ? 2 : (value == '\r' ? 1 : 0);
                case 2 -> value == '\r' ? 3 : 0;
                case 3 -> value == '\n' ? 4 : 0;
                default -> matched;
            };
            if (matched == 4) {
                return new String(bytes.toByteArray(), StandardCharsets.ISO_8859_1);
            }
        }
        throw new IOException("OAuth callback header is too large");
    }

    private static void respond(OutputStream output, int status, String message) throws IOException {
        String html = "<!doctype html><meta charset=utf-8><title>小爱 Spotify 接管</title>"
                + "<meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<body style='font:18px sans-serif;padding:2rem;line-height:1.6'>"
                + message + "</body>";
        byte[] body = html.getBytes(StandardCharsets.UTF_8);
        String head = "HTTP/1.1 " + status + (status == 200 ? " OK" : " Bad Request") + "\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Cache-Control: no-store\r\n"
                + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
                + "X-Content-Type-Options: nosniff\r\n"
                + "Connection: close\r\n"
                + "Content-Length: " + body.length + "\r\n\r\n";
        output.write(head.getBytes(StandardCharsets.US_ASCII));
        output.write(body);
        output.flush();
    }

    @Override
    public void close() throws IOException {
        server.close();
    }
}
