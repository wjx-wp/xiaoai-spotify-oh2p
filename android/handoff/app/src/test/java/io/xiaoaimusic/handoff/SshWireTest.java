package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import java.math.BigInteger;
import java.security.interfaces.RSAPublicKey;
import org.junit.Test;

public final class SshWireTest {
    private static final byte[] EXPECTED_RSA_BLOB = new byte[] {
            0, 0, 0, 7, 's', 's', 'h', '-', 'r', 's', 'a',
            0, 0, 0, 3, 1, 0, 1,
            0, 0, 0, 3, 0, (byte) 0x80, 1
    };

    @Test
    public void rsaPublicKeyBlobEncodesSshStringsAndPositiveMpInts() {
        RSAPublicKey key = new FixedRsaPublicKey(
                new BigInteger(1, new byte[] {(byte) 0x80, 1}),
                BigInteger.valueOf(65_537L));

        assertArrayEquals(EXPECTED_RSA_BLOB, SshWire.rsaPublicKeyBlob(key));
    }

    @Test
    public void openSshPublicKeyContainsTypeBlobAndComment() {
        RSAPublicKey key = new FixedRsaPublicKey(
                new BigInteger(1, new byte[] {(byte) 0x80, 1}),
                BigInteger.valueOf(65_537L));

        assertEquals(
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAAwCAAQ== xiaoai-mobile-auth",
                SshWire.openSshRsaPublicKey(key, "xiaoai-mobile-auth"));
        assertEquals(
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAAwCAAQ==",
                SshWire.openSshRsaPublicKey(key, null));
        assertEquals(
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAAwCAAQ==",
                SshWire.openSshRsaPublicKey(key, "   "));
    }

    @Test
    public void signatureBlobEncodesAlgorithmAndOpaqueSignatureAsSshStrings() {
        assertArrayEquals(
                new byte[] {
                        0, 0, 0, 12,
                        'r', 's', 'a', '-', 's', 'h', 'a', '2', '-', '2', '5', '6',
                        0, 0, 0, 4, 0, 0x7f, (byte) 0x80, (byte) 0xff
                },
                SshWire.signatureBlob(
                        "rsa-sha2-256", new byte[] {0, 0x7f, (byte) 0x80, (byte) 0xff}));
    }

    private static final class FixedRsaPublicKey implements RSAPublicKey {
        private static final long serialVersionUID = 1L;

        private final BigInteger modulus;
        private final BigInteger exponent;

        FixedRsaPublicKey(BigInteger modulus, BigInteger exponent) {
            this.modulus = modulus;
            this.exponent = exponent;
        }

        @Override
        public BigInteger getPublicExponent() {
            return exponent;
        }

        @Override
        public BigInteger getModulus() {
            return modulus;
        }

        @Override
        public String getAlgorithm() {
            return "RSA";
        }

        @Override
        public String getFormat() {
            return null;
        }

        @Override
        public byte[] getEncoded() {
            return null;
        }
    }
}
