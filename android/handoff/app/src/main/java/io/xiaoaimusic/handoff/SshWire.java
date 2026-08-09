package io.xiaoaimusic.handoff;

import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.interfaces.RSAPublicKey;
import java.util.Base64;

final class SshWire {
    static byte[] rsaPublicKeyBlob(RSAPublicKey key) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        writeField(out, "ssh-rsa".getBytes(StandardCharsets.US_ASCII));
        writeField(out, positiveMpInt(key.getPublicExponent()));
        writeField(out, positiveMpInt(key.getModulus()));
        return out.toByteArray();
    }

    static String openSshRsaPublicKey(RSAPublicKey key, String comment) {
        String bare = "ssh-rsa " + Base64.getEncoder().encodeToString(rsaPublicKeyBlob(key));
        return comment == null || comment.isBlank() ? bare : bare + " " + comment;
    }

    static byte[] signatureBlob(String algorithm, byte[] signature) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        writeField(out, algorithm.getBytes(StandardCharsets.US_ASCII));
        writeField(out, signature);
        return out.toByteArray();
    }

    private static byte[] positiveMpInt(BigInteger value) {
        byte[] raw = value.toByteArray();
        if (raw.length > 1 && raw[0] == 0 && (raw[1] & 0x80) == 0) {
            byte[] trimmed = new byte[raw.length - 1];
            System.arraycopy(raw, 1, trimmed, 0, trimmed.length);
            return trimmed;
        }
        return raw;
    }

    private static void writeField(ByteArrayOutputStream out, byte[] value) {
        byte[] length = ByteBuffer.allocate(4).putInt(value.length).array();
        out.write(length, 0, length.length);
        out.write(value, 0, value.length);
    }

    private SshWire() {}
}
