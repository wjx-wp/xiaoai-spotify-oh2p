package io.xiaoaimusic.handoff;

import android.net.Network;

import com.jcraft.jsch.SocketFactory;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;

final class NetworkBoundSocketFactory implements SocketFactory {
    private final Network network;
    private final int connectTimeoutMs;

    NetworkBoundSocketFactory(Network network, int connectTimeoutMs) {
        this.network = network;
        this.connectTimeoutMs = connectTimeoutMs;
    }

    @Override
    public Socket createSocket(String host, int port) throws IOException {
        Socket socket = network.getSocketFactory().createSocket();
        try {
            socket.connect(new InetSocketAddress(host, port), connectTimeoutMs);
            return socket;
        } catch (IOException failure) {
            try {
                socket.close();
            } catch (IOException ignored) {
                // Preserve the original connect failure.
            }
            throw failure;
        }
    }

    @Override
    public InputStream getInputStream(Socket socket) throws IOException {
        return socket.getInputStream();
    }

    @Override
    public OutputStream getOutputStream(Socket socket) throws IOException {
        return socket.getOutputStream();
    }
}
